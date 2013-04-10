#
## $Id: rrdfunc.pm,v 8.6 2012/04/28 00:59:36 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System (“NMIS”).
#  
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#  
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#  
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).  
#  If not, see <http://www.gnu.org/licenses/>
#  
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com 
#  
#  User group details:
#  http://support.opmantek.com/users/
#  
# *****************************************************************************

package rrdfunc;

use NMIS::uselib;
use lib "$NMIS::uselib::rrdtool_lib";

require 5;

use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

use RRDs 1.000.490; # from Tobias
use Statistics::Lite qw(min max range sum count mean median mode variance stddev statshash statsinfo);
use func;
use Sys;
#use Data::Dumper;
#$Data::Dumper::Ident=1;
#$Data::Dumper::SortKeys=1;

$VERSION = 2.0;

@ISA = qw(Exporter);

@EXPORT = qw(
		getRRDasHash
		getRRDStats
		addDStoRRD
		updateRRD
		createRRD
	);

@EXPORT_OK = qw(	
	);

sub getRRDasHash {
	my %args = @_;
	my $S = $args{sys};
	my $graphtype = $args{graphtype};
	my $index = $args{index};
	my $item = $args{item};

	my $db = $S->getDBName(graphtype=>$graphtype,index=>$index,item=>$item);

	my ($begin,$step,$name,$data) = RRDs::fetch($db,$args{mode},"--start",$args{start},"--end",$args{end});
	my %s;
	my @h;
	my $f = 1;
	my $date;
	my $d;
	my $time = $begin;
	for(my $a = 0; $a <= $#{$data}; ++$a) {
		$d = 0;
		for(my $b = 0; $b <= $#{$data->[$a]}; ++$b) {
			if ($f) { push(@h,$name->[$b]) }
			$s{$time}{$name->[$b]} = $data->[$a][$b];
			if ( defined $data->[$a][$b] ) { $d = 1; }
		}
		if ($d) {
			$date = returnDateStamp($time);
			$s{$time}{time} = $time;
			$s{$time}{date} = $date;
		}
		if ($f) { 
			push(@h,"time");
			push(@h,"date");
		}
		$f = 0;
		$time = $time + $step;
	}
	return (\%s,\@h);
}

sub getRRDStats {
	my %args = @_;
	my $S = $args{sys};
	my $graphtype = $args{graphtype};
	my $index = $args{index};
	my $item = $args{item};

	my $db = $S->getDBName(graphtype=>$graphtype,index=>$index,item=>$item);

	if ( ! defined $args{mode} ) { $args{mode} = "AVERAGE"; }
	if ( -r $db ) {
		my ($begin,$step,$name,$data) = RRDs::fetch($db,$args{mode},"--start",$args{start},"--end",$args{end});
		my %s;
		my $time = $begin;
		for(my $a = 0; $a <= $#{$data}; ++$a) {
			my $date = returnDateStamp($time);
			my $hour = $date;
			my $f = 1;
			$hour =~ s/\d+-[a-zA-Z]+-\d+ (\d+):\d+:\d+/$1/;		
			for(my $b = 0; $b <= $#{$data->[$a]}; ++$b) {
				if ( (	defined $data->[$a][$b] 
						and ! defined $args{hour_from}
						and ! defined $args{hour_to}
					) or ( 
						defined $data->[$a][$b] 
						and defined $args{hour_from} 
						and defined $args{hour_to} 
						and $hour > $args{hour_from} 
						and $hour < $args{hour_to} 
					)
				) {
					if ($f) { 
						#print "$date hour=$hour\n";
						$f = 0;
					}
					push(@{$s{$name->[$b]}{values}},$data->[$a][$b]);
				}
			}
			$time = $time + $step;
		}

		foreach my $m (sort keys %s) {
			$s{$m}{stddev} = sprintf("%.3f",stddev(@{$s{$m}{values}}));
			$s{$m}{mean} = sprintf("%.3f",mean(@{$s{$m}{values}}));
			$s{$m}{median} = sprintf("%.3f",median(@{$s{$m}{values}}));
			$s{$m}{min} = sprintf("%.3f",min(@{$s{$m}{values}}));
			$s{$m}{max} = sprintf("%.3f",max(@{$s{$m}{values}}));
			$s{$m}{range} = sprintf("%.3f",range(@{$s{$m}{values}}));
			$s{$m}{sum} = sprintf("%.3f",sum(@{$s{$m}{values}}));
			$s{$m}{count} = sprintf("%.3f",count(@{$s{$m}{values}}));
			$s{$m}{variance} = sprintf("%.3f",variance(@{$s{$m}{values}}));
		}
		return \%s;
	} else {
		logMsg("ERROR RRD is not readable rrd=$db");
		return undef;
	}
}

#
# add a DataSource to an existing RRD
# Cologne, dec 2004
# $rrd = filename of RRD, @ds = list of DS:name:type:hearthbeat:min:max
#
sub addDStoRRD {
	my ($rrd, @ds) = @_ ;

	dbg("update $rrd with @ds");

	my $rrdtool = "rrdtool";
	if ($NMIS::kernel =~ /win32/i) {
		$rrdtool = "rrdtool.exe";
	}
	my $info = `$rrdtool`;
	if ($info eq "") {
		$rrdtool = "/usr/local/rrdtool/bin/rrdtool"; # maybe this
		$info = `$rrdtool`;
		if ($info eq "") {
			logMsg("ERROR, rrdtool not found");
			return;
		}
	}

	# version of rrdtool
	my $version = "10";
	if ($info =~ /.*RRDtool\s+(\d+)\.(\d+)\.(\d+).*/) {
		dbg("RRDtool version is $1.$2.$3");
		$version = "$1$2";
	}

	my $DSname;
	my $DSvalue;
	my $DSprep;

	# Get XML Output
	my $xml = `$rrdtool dump $rrd`;

	#prepare inserts
	foreach my $ds (@ds) {
		if ( $ds =~ /^DS:([a-zA-Z0-9_]{1,19}):(\w+):(\d+):([\dU]+):([\dU]+)/) {
				# Variables
				my $dsName      = $1;
				my $dsType      = $2;
				my $dsHeartBeat = $3;
				my $dsMin       = $4 eq 'U' ? 'NaN' : $4;
				my $dsMax       = $5 eq 'U' ? 'NaN' : $5;

	 		if ( $dsType ne "GAUGE" and $dsType ne "COUNTER" and $dsType ne "DERIVE" and $dsType ne "ABSOLUTE" ) {
				logMsg("ERROR, unknown DS type in $ds");
				return undef;
			}
			if ($xml =~ /<name> $dsName </) {
				logMsg("DS $ds already in database $ds");
			} else {

				$DSname .= "	<ds>
			<name> $dsName </name>
			<type> $dsType </type>
			<minimal_heartbeat> $dsHeartBeat </minimal_heartbeat>
			<min> $dsMin </min>
			<max> $dsMax </max>
		
			<!-- PDP Status -->
			<last_ds> UNKN </last_ds>
			<value> 0.0000000000e+00 </value>
			<unknown_sec> 0 </unknown_sec>
		</ds>\n";

				$DSvalue = $DSvalue eq "" ? "<v> NaN " : "$DSvalue </v><v> NaN ";

				if ($version > 11) {
					$DSprep .= "
				 <ds>
				<primary_value> 0.0000000000e+00 </primary_value>
				<secondary_value> 0.0000000000e+00 </secondary_value>
				<value> NaN </value>  <unknown_datapoints> 0 </unknown_datapoints></ds>\n";
				} else {
					$DSprep .= "<ds><value> NaN </value>  <unknown_datapoints> 0 </unknown_datapoints></ds>\n";
				}			
			}
		}
	}

	if ($DSname ne "" ) {
		if ( $xml =~ /Round Robin Archives/ ) {
			# check priv.
			if ( -w $rrd ) {
		 		# Move the old source
	   			if (rename($rrd,$rrd.".bak")) {
					dbg("$rrd moved to $rrd.bak");
					if ( -e "$rrd.xml" ) {
						# from previous action
						unlink $rrd.".xml";
						dbg("$rrd.xml deleted (previous action)");
					}
					# update xml and rite output
					if (open(OUTF, ">$rrd.xml")) {
						foreach my $line (split(/\n/,$xml)) {
							if ( $line=~ /Round Robin Archives/ ) {
								print OUTF $DSname.$line;
							} elsif ($line =~ /^(.+?<row>)(.+?)(<\/row>.*)$/) {
								my @datasources_in_entry = split(/<\/v>/, $2);
								splice(@datasources_in_entry, 999, 0, "$DSvalue");
								my $new_line = join("</v>", @datasources_in_entry);
								print OUTF "$1$new_line</v>$3\n";
							} elsif ($line =~ /<\/cdp_prep>/) {
								print OUTF $DSprep.$line ;
							} else {
								print OUTF $line;
							}
						}
						close (OUTF);
						dbg("xml written to $rrd.xml");
						# Re-import
						RRDs::restore($rrd.".xml",$rrd);
						if (my $ERROR = RRDs::error) {
							logMsg("update ERROR database=$rrd: $ERROR");
						} else {
							dbg("$rrd created");
							setFileProt($rrd); # set file owner/permission, default: nmis, 0775
							#`chown nmis:nmis $rrd` ; # set owner
							# Delete
							unlink $rrd.".xml";
							dbg("$rrd.xml deleted");
							unlink $rrd.".bak";
							dbg("$rrd.bak deleted");
							logMsg("INFO DataSource @ds added to $rrd");
							return 1;
						}
					} else {
						logMsg("ERROR, could not open $rrd.xml for writing, $!");
						rename($rrd.".bak",$rrd); # backup
					}
				} else {
					dbg("ERROR, cannot rename $rrd, $!") ;
				}
			} else {
				dbg("ERROR, no write permission for $rrd, $!") ;
			}
		} else {
   			dbg("ERROR, could not dump (maybe rrdtool missing): $!");
		}
	} 

}

sub getFileName {
	my %args = @_;
	my $S = $args{sys};
	my $type = $args{type};
	my $index = $args{index};
	my $item = $args{item};
	my $nmis4 = $args{nmis4};
	my $C = loadConfTable();

	if (!$S) {
		$S = Sys::->new(); # get base Model containing database info
		$S->init;
	}

	my $dir;

	# get the rule in Model to find the database file
	if ($S->{mdl}{database}{type}{$type}) {
		my $string = $S->{mdl}{database}{type}{$type};
		$string =~ s/\$node\b/\$host/g if $nmis4 eq 'true';
		if ($dir = $S->parseString(string=>$string,type=>$type,index=>$index,item=>$item)) {
			#		
			$dir = $C->{database_root}.$dir; # full specification
			dbg("filename of type=$type is $dir");
		}
	} else {
		logMsg("ERROR, ($S->{name}) no type=$type found in class=database of model=$S->{mdl}{system}{nodeModel}");
	}
	return $dir;
}

sub updateRRD {
	my %args = @_;
	my $S = $args{sys};
	my $NI = $S->{info};
	my $IF = $S->{intf};

	my $data = $args{data};
	my $type = $args{type};
	my $index = $args{index};
	my $item = $args{item};

	my $database = $args{database};

	dbg("Starting RRD Update Process, type=$type, index=$index,item=$item");

	if ($database eq "") {

		if (! ($database = getFileName(sys=>$S,type=>$type,index=>$index,item=>$item))) {
			return; # error
		}

		# Does the database exist ?
		if ( -f $database and -r $database and -w $database ) { 
			# its oke !
			dbg("database $database exists and is R/W");
		}
		# Check if the RRD Database Exists but is ReadOnly
		# Maybe this should check for valid directory or not.
		elsif ( -f $database and not -w $database ) {
			$S->{error} = "ERROR ($S->{name}) database $database Exists but is readonly";
			logMsg($S->{error});
			return;
		} else {
			# maybe version nmis4 with hostname
			my $database4;
			dbg("file=$database not found, try nmis4 format");
			if (! ($database4 = getFileName(sys=>$S,type=>$type,index=>$index,item=>$item,nmis4=>'true'))) {
				return; # error
			}
			if ( -f $database4 and -r $database4 and -w $database4 ) { 
				# its oke !
				$database = $database4;
				dbg("database $database exists and is R/W");
			} else {
				if (! createRRD(data=>$data,sys=>$S,type=>$type,database=>$database,index=>$index)) {
					return; # error
				}
			}
		}
	} else {
		# no check
		dbg("database $database");
	}


	my @options;
	my $ERROR;
	my $ds;
	my $value = "N";

	foreach my $var (keys %{$data}) {
		$ds .= ":" if $ds ne "";
		$ds .= $var;
		# cleanup invalid values
		$data->{$var}{value} = 0 if $data->{$var}{value} eq "noSuchObject" or $data->{$var}{value} eq "noSuchInstance" or $data->{$var}{value} eq "";
		$data->{$var}{value} = "U" if $data->{$var}{value} eq "N/A";
		$value .= ":$data->{$var}{value}";
	}
	push @options,("-t",$ds,$value);

	dbg("DS $ds");
	dbg("value $value");
	
	logPolling("$type,$NI->{system}{name},$index,$item,$ds,$value");

	if ( @options) {
		# update RRD
		RRDs::update($database,@options);
		#my $upd = RRDs::updatev($database,@options);	
		#print STDERR Dumper($upd);
		
		if ($ERROR = RRDs::error) {
			if ($ERROR !~ /contains more DS|unknown DS name/) {
				$S->{error} = "ERROR ($S->{name}) database=$database: $ERROR: options = @options";
				logMsg($S->{error});
			} else {
				dbg("missing DataSource in $database, try to update");
				# find the DS names in the existing database (format ds[name].* )
				my $info = RRDs::info($database);
				my $names = ":";
				foreach my $key (keys %$info) {
					if ( $key =~ /^ds\[([a-zA-Z0-9_]{1,19})\].+/) { $names .= "$1:";}
				}
				# find the missing DS name (format DS:name:type:hearthbeat:min:max)
				my @options_db = optionsRRD(data=>$data,sys=>$S,type=>$type,index=>$index);
				foreach my $ds (@options_db) {
					my @opt = split /:/, $ds;
					if ( $opt[0] eq "DS" and $names !~ /:$opt[1]:/ ) {
						&addDStoRRD($database,$ds); # sub in rrdfunc
					}
				}
			}
		}
	}
	else {
		logMsg("ERROR ($S->{name}) type=$type, no data to create/update database");
	}
	return $database;
	dbg("Finished");
} # end updateRRD

#
# define the DataSource configuration for RRD
#
sub optionsRRD {
	my %args = @_;
	my $S = $args{sys}; # optional,needed for parsing range
	my $data = $args{data};
	my $type = $args{type}; 
	my $index = $args{index}; # optional

	my $time  = 30*int(time/30);
	my $START = $time;
	my @options;

	dbg("type $type");

	my $M;
	if ($S eq "") {
		$M = Sys::->new(); # load base model
		$M->init;
	} else {
		$M = $S;
	}

	my $RRD_poll;
	my $RRD_hbeat;
	if (!($RRD_poll = $M->{mdl}{database}{db}{poll})) { $RRD_poll = 300;}
	if (!($RRD_hbeat = $M->{mdl}{database}{db}{hbeat})) { $RRD_hbeat = $RRD_poll * 3;}


	@options = ("-b", $START, "-s", $RRD_poll);

	#
	# $data{ds_name}{value} contains the values
	# $data{ds_name}{option} contains the info for creating the dds, format is "source,low:high"
	# where source can be GAUGE,COUNTER etc. low:high are the limits of values to store
	# default is GAUGE,"U:U"
	#
	# get the keys of the hash to create the identifiers
	foreach my $id (sort keys %{$data}) {
		if (length($id) > 18) {
			logMsg("ERROR, DS name=$id greater then 18 characters") ;
			next;
		}
		my $source = "GAUGE";
		my $range = "U:U";
		if ($data->{$id}{option} ne "") {
			($source,$range) = split (/\,/,$data->{$id}{option});
			$range = $S->parseString(string=>$range,sys=>$S,type=>$type,index=>$index) if $S ne "";
			$source = uc $source;
		}
		dbg("ID of data is $id, source $source, range $range",2);
		push @options,"DS:$id:$source:$RRD_hbeat:$range";
	}

	my $DB;
	if (exists $M->{mdl}{database}{db}{size}{$type}) {
		$DB = $M->{mdl}{database}{db}{size}{$type};
	} elsif (exists $M->{mdl}{database}{db}{size}{default}) {
		$DB = $M->{mdl}{database}{db}{size}{default};
		dbg("INFO, using database format \'default\'");
	}

	if ($DB eq "") {
		dbg("ERROR ($S->{name}) database format for type=$type not found");
	} else {

		push @options,"RRA:AVERAGE:0.5:$DB->{step_day}:$DB->{rows_day}";
		push @options,"RRA:AVERAGE:0.5:$DB->{step_week}:$DB->{rows_week}";
		push @options,"RRA:AVERAGE:0.5:$DB->{step_month}:$DB->{rows_month}";
		push @options,"RRA:AVERAGE:0.5:$DB->{step_year}:$DB->{rows_year}";
		push @options,"RRA:MAX:0.5:$DB->{step_day}:$DB->{rows_day}";
		push @options,"RRA:MAX:0.5:$DB->{step_week}:$DB->{rows_week}";
		push @options,"RRA:MAX:0.5:$DB->{step_month}:$DB->{rows_month}";
		push @options,"RRA:MAX:0.5:$DB->{step_year}:$DB->{rows_year}";
		push @options,"RRA:MIN:0.5:$DB->{step_day}:$DB->{rows_day}";
		push @options,"RRA:MIN:0.5:$DB->{step_week}:$DB->{rows_week}";
		push @options,"RRA:MIN:0.5:$DB->{step_month}:$DB->{rows_month}";
		push @options,"RRA:MIN:0.5:$DB->{step_year}:$DB->{rows_year}";
		
		push @options,"RRA:HWPREDICT:1440:0.1:0.0035:288";  
		
		#RRA:HWPREDICT:1440:0.1:0.0035:288
		
#		push @options,"RRA:MIN:0.5:$DB->{step_year}:$DB->{rows_year}";
#		push @options,"RRA:MIN:0.5:$DB->{step_year}:$DB->{rows_year}";
#		push @options,"RRA:MIN:0.5:$DB->{step_year}:$DB->{rows_year}";
#		push @options,"RRA:MIN:0.5:$DB->{step_year}:$DB->{rows_year}";
#		push @options,"RRA:MIN:0.5:$DB->{step_year}:$DB->{rows_year}";
#
#
#rrdtool create monitor.rrd --step 300 \
#   DS:ifOutOctets:COUNTER:1800:0:4294967295 \
#   RRA:AVERAGE:0.5:1:2016 \
#   RRA:HWPREDICT:1440:0.1:0.0035:288:3 \
#   RRA:SEASONAL:288:0.1:2 \
#   RRA:DEVPREDICT:1440:5 \
#   RRA:DEVSEASONAL:288:0.1:2 \
#   RRA:FAILURES:288:7:9:5

		return @options;
	}
	return;
} # end optionsRRD


### createRRRDB now checks if RRD exists and only creates if doesn't exist.
### also add node directory create for node directories, if rrd is not found
sub createRRD {
	my %args = @_;
	my $S = $args{sys}; # optional
	my $data = $args{data};
	my $type = $args{type};
	my $index = $args{index};
	my $database = $args{database};

	my $exit = 1;

	dbg("Starting");
	dbg("check and/or create RRD database $database");

	# Does the database exist already?
	if ( -f $database and -r $database and -w $database ) { 
		# nothing to do!
		dbg("Database $database exists and is R/W");
	}
	# Check if the RRD Database Exists but is ReadOnly
	# Maybe this should check for valid directory or not.
	elsif ( -f $database and not -w $database ) { 
		dbg("ERROR ($S->{name}) database $database Exists but is readonly");
		$exit = 0;
	}
	# It doesn't so create it
	else {
		my @x = $database =~ /\//g; # until last slash
		my $dir = $`; # before last slash
		# let check if the node directory exists as well, create if not.
		if ( not -d "$dir" 
			and not -r "$dir" 
		) { 
			dbg("creating database directory $dir");
			mkdir $dir, 0775 or warn "Cannot mkdir $dir: $!\n";
		}

		my @options = optionsRRD(data=>$data,sys=>$S,type=>$type,index=>$index);

		if ( @options ) {
			dbg("options to create database $database");
			foreach my $t (@options) {
				dbg($t);
			}
			RRDs::create("$database",@options);
			my $ERROR = RRDs::error;
			if ($ERROR) {
				logMsg("ERROR ($S->{name}) unable to create $database: $ERROR");
				$exit = 0;
			}
			# set file owner and permission, default: nmis, 0775.
			setFileProt($database); # Cologne, Jan 2005
			# Double check created OK for this user
			if ( -f $database and -r $database and -w $database ) { 
				logMsg("INFO ($S->{name}) created RRD $database");
				sleep 1;		# wait at least 1 sec to avoid rrd 1 sec step errors as next call is RRDBupdate
			}
			else {
				logMsg("ERROR ($S->{name}) could not create RRD $database - check directory permissions");
				$exit = 0;
			}
		}
		else {
			logMsg("ERROR ($S->{name}) unknown type=$type");
			$exit = 0;
		}
	}
	dbg("Finished");
	return $exit;
} # end createRRD

1;