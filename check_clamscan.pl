#!/usr/bin/perl
# check_clam_scan: Nagios/Icinga plugin to check status of
# clam anti virus scanner
#
# Copyright (C) 2012 Thomas-Krenn.AG,
# For a list of contributors see changelog.txt
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
# details.
# 
# You should have received a copy of the GNU General Public License along with
# this program; if not, see <http://www.gnu.org/licenses/>.
#
################################################################################
# The following guides provide helpful information if you want to extend this
# script:
#   http://nagiosplug.sourceforge.net/developer-guidelines.html (plug-in
#                  development guidelines)
################################################################################

use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);#case sensitive
use Proc::ProcessTable;#check if scanner is running
use File::stat;
use Switch;
use Date::Calc qw(Delta_Days);

our $CLAMSCAN;#path to clamscan binary
#warning and critical threshold levels
our %PERF_THRESHOLDS = (
	scan_interval => ['2','5'], #days between scans
	infected_files => ['1','1'], #number of infected files
);


sub getVersion{
		return "check_clamscan version 0.1 20120912
Copyright (C) 2012 Thomas-Krenn.AG (written by Georg Schönberger)
Current updates available via git repository git.thomas-krenn.com.
Your system is using ".getClamscanVersion();
}
sub getClamscanVersion{
	if($CLAMSCAN eq ''){
		print "Error: Could not find clamscan binary with 'which clamscan'.\n";
		exit(3);
	}
	else{
		return `clamscan -V`;
	}
}
sub getUsage{
	return "Usage:
check_clamscan -sd <scanned directory> -l <clamscan log file> | [-w <list of warn levels>]
[-c <list of crit levels>] [-v|-vv|-vvv] [-h] [-V]"
}
sub getHelp{
	return "

  [-sd <scanned directory>]
        Provide the path to the directory scanned by clamscan. This is useful to detect if
        clamscan is currently running and scanning the directory.
  [-l <clamscan log file>]
        Provide the path to the clamscan log output. Clamscan should be called with
        the '--stdout' and the output redirected to the log file via '>'.
        E.g. clamscan -r /files --stdout > clamscan.log
  [-w <list of warning thresholds>]
       Change the default warning levels. The order of the levels
       is the following:
       -scan_interval
       -infected_files
       Levels that should stay default get a 'd' assigned.
       Example:
           check_clamscan.pl -w '5,d' 
       This changes the warning level for the scan interval to 5 days.
  [-c <list of critical thresholds>]
       Change the default critical levels. The order of the levels
       is the same as for the warning levels.
       Levels that should stay default get a 'd' assigned.
       Example:
           check_gpu_sensor.pl -c '7,d' 
       This changes the critical level for the scan interval to 7 days.  		
  [-v <Verbose Level>]
       be verbose
         (no -v) .. single line output
         -v ..... single line output with additional details for warnings
         -vv ..... multi line output, also with additional details for warnings
         -vvv ..... normal output, then debugging output, followed by normal multi line output
  [-h]
       show this help
  [-V]
       show version information";
}
sub checkClamscanBin{
	my $clamBin = `which clamscan 2>&1`;
	if($clamBin =~ m/clamscan/){
		return $clamBin;
	}
	return '';
}
sub clamIsRunning{
	my $scanDir = quotemeta(shift);#the scanned directory
	my $t = new Proc::ProcessTable;
	foreach my $p ( @{$t->table} ){
		if($p->cmndline =~ m/^clamscan.+$scanDir/){
			return(1,$p->pid,scalar(localtime($p->start)));
		}
	}
	return (0,0,0);
}

sub parseClamLog{
	my $clamLog = shift;
	my %scanStat;
	open(my $fd, "<", $clamLog)
    	or die "Error: Cannot open < $clamLog: $!";
	
	my $pattern = "SCAN SUMMARY";
	my $found;
	while(<$fd>){
		my $line = $_;
		chomp($line);
		#Check if scan summary is found
		if($line =~ m/$pattern/){
			$found = 1;
			next;
		}
		#From summary on use status of scan
		#Split at : and use values after it
		#Lower key and substitute whitespaces
		if($found){
			my @clamStat = split(': ',$line);
			$clamStat[0] = lc $clamStat[0];
			$clamStat[0] =~ s/\s/\_/g;
			
			#remove whitespace from values
			$clamStat[1] =~ s/\s//g;
			#remove everything after MB
			if($clamStat[1] =~ m/MB.*/){
				$clamStat[1] =~ s/(MB).*/$1/;	
			}
			#change from sec to s
			if($clamStat[1] =~ m/(\d+\.\d+)(sec).*/){
				my $newStat = $clamStat[1]; 
				$newStat =~ /(\d+\.\d+)(sec).*/;
				$clamStat[1] = $1.'s'
			}
			$scanStat{$clamStat[0]} = $clamStat[1];
		}		
	}
	return %scanStat;
}

sub getLastModified{
	my $clamLog = shift;
	my @logStat = stat($clamLog);
	#index 9 is mtime of stat
	my $mtime = $logStat[0][9];
	my $modDate = localtime($mtime);
	my @a_mtime = (localtime($mtime));
	my @today = localtime;
	my $dD = Delta_Days($today[5],$today[4],$today[3],
						$a_mtime[5],$a_mtime[4],$a_mtime[3]);
	#as run was in the past mutiply with -1
	return ($dD * -1,$modDate);
}

sub checkThlds{
	my @warnThlds = @{(shift)};
	my @critThls = @{(shift)};
	my %perfData = %{(shift)};
	
	my $i = 0;
	if(@warnThlds){
		@warnThlds = split(/,/, join(',', @warnThlds));
		for ($i = 0; $i < @warnThlds; $i++){
			#everything, except that values that sould stay default, get new values
			if($warnThlds[$i] ne 'd'){
				switch($i){
					case 0 {$PERF_THRESHOLDS{'scan_interval'}[0] = $warnThlds[$i]};
				}					
			}		
		}			
	}
	if(@critThls){
		@critThls = split(/,/, join(',', @critThls));
		for ($i = 0; $i < @critThls; $i++){
			if($critThls[$i] ne 'd'){
				switch($i){
					case 0 {$PERF_THRESHOLDS{'scan_interval'}[1] = $critThls[$i]};
				}
			}		
		}			
	}
	#start with OK
	my @statusLevel = ("OK");
	my @warnSens = ();#warning sensors
	my @critSens = ();#crit sensors
	foreach my $k (keys %perfData){
		if(exists $PERF_THRESHOLDS{$k}){
			#warning level
			if($perfData{$k} >= $PERF_THRESHOLDS{$k}[0]){
				$statusLevel[0] = "Warning";
				push(@warnSens,$k);
			}
			#critical level
			if($perfData{$k} >= $PERF_THRESHOLDS{$k}[1]){
				$statusLevel[0] = "Critical";
				pop(@warnSens);#as it is critical, remove it from warning
				push(@critSens,$k);
			}
		}		
	}
	push(@statusLevel,\@warnSens);
	push(@statusLevel,\@critSens);
	return \@statusLevel;
}
#Form a status string with warning, crit sensor values
#or performance data followed by their thresholds
sub getStrStatus{
	my $level = shift;
	my $currSensors = shift;
	my $perfData = shift;
	my $verbosity = shift;
	my $str_status = "";

	if($level ne "Warning" && $level ne "Critical"
		&& $level ne "Performance"){
		return;
	}
	if($level eq "Warning"){
		$currSensors = $currSensors->[1];
	}
	if($level eq "Critical"){
		$currSensors = $currSensors->[2];
	}
	my $i = 1;
	#Collect performance data of warn and crit sensors
	if($level eq "Warning" || $level eq "Critical"){
		if(@$currSensors){
			foreach my $sensor (@$currSensors){
				$str_status .= "[".$sensor." = ".$level;
				if($verbosity){
					$str_status .= " (".$perfData->{$sensor}.")";	
				}
				$str_status .= "]";
				if($i != @$currSensors){
					$str_status .= " ";#print a space except at the end
				}
				$i++;
			}
		}
	}
	#Collect performance values followed by thresholds
	if($level eq "Performance"){
		foreach my $k (keys %$currSensors){
			$str_status .= $k."=".$currSensors->{$k};
			#print warn and crit thresholds
			if(exists $PERF_THRESHOLDS{$k}){
				$str_status .= ";".$PERF_THRESHOLDS{$k}[0];
				$str_status .= ";".$PERF_THRESHOLDS{$k}[1].";";
			}
			if($i != (keys %$currSensors)){
				$str_status .= " ";
			}
			$i++;
		}	
	}
	return $str_status;
}
sub getStrVerbose{
	my $verbosity = shift;
	my $scanDir = shift;
	my $clamLog = shift;
	my %scanStat = %{(shift)};
	my $str_status = "";
	
	if($verbosity == 3){
		$str_status .= "------------- begin of debug output (-vvv is set): ------------\n";
		$str_status .= "ClamAV version: ".getClamscanVersion();
		$str_status .= "ClamAV binary: ".$CLAMSCAN;
		$str_status .= "ClamAV scanned directory: ".$scanDir."\n";
		$str_status .= "ClamAV log output: ".$clamLog."\n";
		$str_status .= "----Available scan summary----\n";
		foreach my $k (keys %scanStat){
			$str_status .= $k." : ".$scanStat{$k}."\n";			
		}
	}
	if($verbosity == 3){
		$str_status .= "------------- end of debug output ------------\n";
		$str_status .= getStrStatus("Performance",\%scanStat);
	}
	return $str_status;
}
MAIN: {
	
	#First, check for clamscan binary
	my $clamBin = checkClamscanBin();
	if($clamBin ne ''){
		$CLAMSCAN = $clamBin;
	}
	else{
		print "Error: Could not find clamscan binary with 'which clamscan'.\n";
		exit(3);
	}
	my $verbosity = 0;#verbose levels
	my $scanDir;#directory to be scanned
	my $clamLog;#log of clamscan
	my @warnThlds = ();#change thresholds for performance data
	my @critThlds = ();
	
	#Parse command line options
	if( !(Getopt::Long::GetOptions(
		'h|help'	=>
		sub{print getVersion();
				print  "\n";
				print getUsage();
				print "\n";
				print getHelp()."\n";
				exit(0);
		},
		'V|version'	=>
		sub{print getVersion()."\n";
				exit(0);
		},
		'v|verbosity'	=>	\$verbosity,
		'vv'			=> sub{$verbosity=2},
		'vvv'			=> sub{$verbosity=3},
		'sd|scandir=s'	=> \$scanDir,
		'l|log=s'	=> \$clamLog,
		'w|warning=s' => \@warnThlds,
		'c|critical=s' => \@critThlds,
	))){
		print getUsage()."\n";
		exit(1);
	}
	if(@ARGV){
		#we don't want any unused command line arguments
		print getUsage()."\n";
		exit(3);
	}
	
	#the scanned directory is not given
	if(not defined $scanDir){
		print "Error: Scanned directory by clamscan is required.\n";
		print getUsage()."\n";
		exit(3);
	}
	
	#the clam log file is not given
	if(not defined $clamLog){
		print "Error: Clam log file is required.\n";
		print getUsage()."\n";
		exit(3);
	}
	
	#remove trailing slash if present
	if((substr $scanDir,-1,1) eq '/'){
		chop $scanDir;
	}
	#Check if scan is running
	my($ret,$pid,$start) = clamIsRunning($scanDir);
	
	#Start checking status of clamscan
	my $exitCode = 0;
	my %scanStat = parseClamLog($clamLog);
	($scanStat{'scan_interval'},my $lastRun) = getLastModified($clamLog);

	#check thresholds
	my $statusLevel = checkThlds(\@warnThlds,\@warnThlds,\%scanStat);
	#check return values of threshold function
	if($statusLevel->[0] eq "Critical"){
		$exitCode = 2;#Critical
	}
	if($statusLevel->[0] eq "Warning"){
		$exitCode = 1;#Warning
	}
	#print status and performance values
	print $statusLevel->[0]." - ";
	if($ret eq 1 && $pid ne 0){
		print "Pid ".$pid." since ".$start." ";
	}
	else{
		print "Last run ".scalar($lastRun)." ";
	}
	print getStrStatus("Critical",$statusLevel,\%scanStat,$verbosity);
	print getStrStatus("Warning",$statusLevel,\%scanStat,$verbosity);
	print "|";
	print getStrStatus("Performance",\%scanStat);
	print "\n".getStrVerbose($verbosity,$scanDir,$clamLog,\%scanStat);
	exit($exitCode);
}