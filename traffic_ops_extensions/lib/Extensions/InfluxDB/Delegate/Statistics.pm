package Extensions::InfluxDB::Delegate::Statistics;
#
# Copyright 2011-2014, Comcast Corporation. This software and its contents are
# Comcast confidential and proprietary. It cannot be used, disclosed, or
# distributed without Comcast's prior written permission. Modification of this
# software is only allowed at the direction of Comcast Corporation. All allowed
# modifications must be provided to Comcast Corporation.
#
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use Math::Round qw(nearest);
use JSON;
use POSIX qw(strftime);
use Extensions::InfluxDB::Builder::DeliveryServiceStatsBuilder;
use Extensions::InfluxDB::Utils::InfluxDBDecorator;
use Extensions::InfluxDB::Helper::InfluxResponse;
use HTTP::Date;
use Utils::Helper::DateHelper;
use Carp qw(cluck confess);
use constant SPDB_URL => "http://spdb.g.comcast.net/GetTextBulkDataBySearch";
use Common::ReturnCodes qw(SUCCESS ERROR);
use Utils::Deliveryservice;
use Time::Seconds;
use Time::Piece;
use DateTime::Format::ISO8601;
use constant ONE_DAY_IN_SECONDS => 86400;
use constant THREE_DAYS         => ONE_DAY * 3;

# constants do not interpolate
my $delim = ":";

my $builder;
my $mojo;
my $db_name;

sub new {
	my $self  = {};
	my $class = shift;
	$mojo    = shift;
	$db_name = shift;
	return ( bless( $self, $class ) );
}

sub info {
	return {
		name        => "Statistics",
		version     => "1.2",
		info_url    => "",
		description => "Statistics Stub",
		isactive    => 1,
		script_file => "Extensions::Delegate::Statistics",
	};
}

# InfluxDB+SPDB converted to InfluxDB format
sub get_stats {
	my $self = shift;

	# version 1.2 parameters
	my $ds_name     = $mojo->param("deliveryServiceName");
	my $metric_type = $mojo->param("metricType");
	my $server_type = $mojo->param("serverType");
	my $start_date  = $mojo->param("startDate");
	my $end_date    = $mojo->param("endDate");
	my $stats_only  = $mojo->param("stats");
	my $data_only   = $mojo->param("data");
	my $type        = $mojo->param("type");
	my $interval    = $mojo->param("interval");
	my $match       = $mojo->param("match");
	my $exclude     = $mojo->param("exclude");
	my $orderby     = $mojo->param("orderby");
	my $limit       = $mojo->param("limit");
	my $offset      = $mojo->param("offset");

	# This parameter allows the API to override the retention period because
	# We can't wait for 30 days for data build up if it hasn't been 30 days yet.
	my $retention_period_in_days = $mojo->param("retentionPeriodInDays");

	# Build the summary section
	$builder = new Extensions::InfluxDB::Builder::DeliveryServiceStatsBuilder(
		{
			deliveryServiceName => $ds_name,
			metricType          => $metric_type,
			startDate           => $start_date,
			endDate             => $end_date,
			dbName              => $db_name,
			interval            => $interval,
			orderby             => $orderby,
			exclude             => $exclude,
			limit               => $limit,
			offset              => $offset,
		}
	);

	my $result      = ();
	my $start_epoch = str2time($start_date);
	my $end_epoch   = str2time($end_date);
	my $rc          = SUCCESS;
	my $formatted_response;

	my $retention_period;
	if ( defined($retention_period_in_days) ) {
		$retention_period = $retention_period_in_days * ONE_DAY;
		$mojo->app->log->debug("retentionPeriodInDays=$retention_period_in_days -- OVERRIDDEN");
	}
	else {
		my $default_retention_period = THREE_DAYS;
		$retention_period = $self->lookup_retention_period_from_influx || $default_retention_period;
		$mojo->app->log->debug(
			"Using retention_period for '" . $db_name . "':  " . $retention_period . " seconds or " . $retention_period / ONE_DAY . " days" );
	}

	# -1 minute for diff between client and our time
	my $retention_start = time() - $retention_period - ONE_MINUTE;
	$mojo->app->log->debug( "Start Date #-> " . $start_date );
	$mojo->app->log->debug( "End Date #-> " . $end_date );
	$mojo->app->log->debug( "Retention Start Date #-> " . gmtime($retention_start) );

	# numeric start/end only which should be done upstream but let's be extra cautious
	if ( ( $start_epoch =~ /^\d+$/ && $end_epoch =~ /^\d+$/ ) && ( $start_epoch > $retention_start ) ) {
		$mojo->app->log->debug("Retrieving 'Short Term' stats...");

		( $rc, $formatted_response ) = $self->short_term();
	}
	else {
		$mojo->app->log->debug("Retrieving 'Long Term' stats...");
		( $rc, $formatted_response ) = $self->long_term_influx_from_spdb();
	}
}

sub lookup_retention_period_from_influx {
	my $self = shift;

	#> show retention policies deliveryservice_stats;
	#name   duration    replicaN    default
	#default    0       1       false
	#weekly 120h0m0s    3       true
	my $response_container        = $mojo->influxdb_query( $db_name, "SHOW RETENTION POLICIES $db_name" );
	my $response                  = $response_container->{'response'};
	my $content                   = $response->{_content};
	my $content_hash              = decode_json($content);
	my $retention_period_response = $content_hash->{results}[0]{series}[0]{values}[1][1];
	my $ir                        = new Extensions::InfluxDB::Helper::InfluxResponse();
	$retention_period = $ir->parse_retention_period_in_seconds($retention_period_response);

	return $retention_period;
}

# InfluxDB
sub short_term {
	my $self        = shift;
	my $exclude     = $mojo->param("exclude");
	my $interval    = $mojo->param("interval");
	my $start_date  = $mojo->param("startDate");
	my $end_date    = $mojo->param("endDate");
	my $metric_type = $mojo->param("metricType");
	my $summary_query;
	my $rc = SUCCESS;
	my $result;

	my $include_summary = ( defined($exclude) && $exclude =~ /summary/ ) ? 0 : 1;
	if ($include_summary) {
		( $rc, $result, $summary_query ) = $self->build_summary( $metric_type, $start_date, $end_date, $result );
	}

	if ( $rc == SUCCESS ) {
		my $include_series = ( defined($exclude) && $exclude =~ /series/ ) ? 0 : 1;
		my $series_query;
		if ($include_series) {
			( $rc, $result, $series_query ) = $self->build_series($result);
		}
		if ( $rc == SUCCESS ) {
			$result = build_parameters( $self, $result, $summary_query, $series_query );
		}
		else {
			return ( ERROR, $result );
		}
	}
	else {
		return ( ERROR, $result );
	}
	return ( SUCCESS, $result );
}

# We have to calculate the total_tps because the metrics in
# influx have already been captured in tps so we have to unravel the
# TPS to recalculate the total_tps
sub calculate_total_tps {
	my $self       = shift;
	my $start_date = shift;
	my $end_date   = shift;
	my $average    = shift;

	my $iso8601_fmt = "%Y-%m-%dT%H:%M:%SZ";
	my $s           = DateTime::Format::ISO8601->parse_datetime($start_date);
	my $se          = $s->epoch();

	my $e                   = DateTime::Format::ISO8601->parse_datetime($end_date);
	my $ee                  = $e->epoch();
	my $duration_in_seconds = $ee - $se;
	return $duration_in_seconds * $average;
}

# This method wraps the SPDB call because that call
# 'pads nulls', and 'normalizes', because it's intertwined
# it was just easiest to deal with it's response format.

# For backward compatibility, we have work with the result
#  as JSON because the long_term function can be called by itself.
sub long_term_influx_from_spdb {
	my $self            = shift;
	my $cachegroup_name = $mojo->param("cacheGroupName");
	my $ds_name         = $mojo->param("deliveryServiceName");
	my $metric_type     = $mojo->param("metricType");
	my $start_date      = $mojo->param("startDate");
	my $end_date        = $mojo->param("endDate");
	my $host_name       = $mojo->param("hostName");
	my $interval        = $mojo->param("interval");

	my $start_epoch = str2time($start_date);
	$start_date = $start_epoch;

	my $end_epoch = str2time($end_date);
	$end_date = $end_epoch;

	my $cdn_name = $self->get_cdn_name_by_dsname($ds_name);
	if ( defined($cdn_name) ) {
		$host_name       = $host_name       || "all";
		$ds_name         = $ds_name         || "all";
		$cachegroup_name = $cachegroup_name || "all";
		my $match =
			sprintf( "%s" . $delim . "%s" . $delim . "%s" . $delim . "%s" . $delim . "%s", $cdn_name, $ds_name, $cachegroup_name, $host_name,
			$metric_type );

		$mojo->param( match => $match );

		# for backward compatibility
		$mojo->param( start_date => $start_date );
		$mojo->param( end_date   => $end_date );
		my ( $rc, $result ) = $self->long_term();
		print "result #-> (" . Dumper($result) . ")\n";

		if ( $rc == SUCCESS ) {

			# Flip the SPDB Response to the Influx format now.
			my $ir = new Extensions::InfluxDB::Helper::InfluxResponse();
			$result = $ir->convert_spdb_to_influx_format($result);
			print "result #-> (" . Dumper($result) . ")\n";

			#			my $size = @$result;
			#			if ( $size > 0 ) {
			#				my $metric_interval = $r_to_s{$metric_type}->{interval};
			#
			#				# We need to convert the interval to seconds to remove the Influx formatted interval ie: 60s to become 60
			#				my $ic                  = new Extensions::InfluxDB::Utils::IntervalConverter();
			#				my $interval_in_seconds = $ic->to_seconds($interval);
			#				my $args                = {
			#					cdn                      => $cdn_name,
			#					ds_name                  => $ds_name,
			#					cache_group_name         => $cachegroup_name,
			#					host_name                => $host_name,
			#					interval                 => $interval_in_seconds,
			#					interval_for_metric_type => $metric_interval
			#				};
			#				my $idd = new Extensions::InfluxDB::Utils::InfluxDBDecorator($args);
			#
			#				( $rc, $response ) = $idd->to_influx_series_format( $result, $metric_type, \%r_to_s );
			#				print "response #-> (" . Dumper($response) . ")\n";
			#
			#				if ( ( $rc == SUCCESS ) && defined($response) ) {
			#					if ( ref($response) eq "HASH" && exists( $response->{series} ) ) {
			#						$self->normalize_intervals( $response, $interval );
			#						$self->calc_summary($response);
			#					}
			#				}
			#			}

			if ( keys %$result ) {

				my $ir = new Extensions::InfluxDB::Helper::InfluxResponse();
				$result = $self->build_parameters( $result, undef, undef );
			}
			return ( $rc, $result );
		}
		else {
			return ( ERROR, "CDN Name: '" . $cdn_name . "' and/or Delivery Service Name: '" . $ds_name . "' is not defined in the database." );
		}
	}

	sub calc_summary {
		my $self = shift;
		my $data = shift;

		my $interval = $data->{interval} || return (undef);
		my $stat     = $data->{statName} || return (undef);

		my $convert = {
			kbps => sub {
				my $t = shift;
				my $i = shift;
				return ( ( $t / 8 ) * $i );
			},
			tps => sub {
				my $t = shift;
				my $i = shift;
				return ( $t * $i );
			},
			tps_2xx => sub {
				my $t = shift;
				my $i = shift;
				return ( $t * $i );
			},
			tps_3xx => sub {
				my $t = shift;
				my $i = shift;
				return ( $t * $i );
			},
			tps_4xx => sub {
				my $t = shift;
				my $i = shift;
				return ( $t * $i );
			},
			tps_5xx => sub {
				my $t = shift;
				my $i = shift;
				return ( $t * $i );
			},
			tps_total => sub {
				my $t = shift;
				my $i = shift;
				return ( $t * $i );
			},
		};

		my $summary = {
			min         => undef,
			max         => 0,
			average     => 0,
			ninetyFifth => 0,
			total       => 0,
			samples     => []
		};

		for my $series ( @{ $data->{series} } ) {
			for my $sample ( @{ $series->{samples} } ) {
				if ( !defined($sample) ) {
					next;
				}

				if ( !defined( $summary->{min} ) || $sample < $summary->{min} ) {
					$summary->{min} = $sample;
				}

				if ( $sample > $summary->{max} ) {
					$summary->{max} = $sample;
				}

				$summary->{total} += $sample;
				push( @{ $summary->{samples} }, $sample );
			}
		}

		my @sorted = sort { $a <=> $b } @{ $summary->{samples} };

		my $index = ( scalar(@sorted) * .5 ) - 1;    # calc the index of the 95th percentile, subtract one for real index
		$summary->{fifth} = $sorted[$index];

		$index = ( scalar(@sorted) * .95 ) - 1;      # calc the index of the 95th percentile, subtract one for real index
		$summary->{ninetyFifth} = $sorted[$index];

		$index = ( scalar(@sorted) * .98 ) - 1;       # calc the index of the 95th percentile, subtract one for real index
		$summary->{ninetyEighth} = $sorted[$index];

		if ( $summary->{total} ) {
			if ( scalar( @{ $summary->{samples} } ) > 1 ) {
				$summary->{average} = int( $summary->{total} / scalar( @{ $summary->{samples} } ) );
			}
			else {
				$summary->{average} = $summary->{total};
			}

			if ( exists( $convert->{$stat} ) && $convert->{$stat} ) {
				$summary->{total} = $convert->{$stat}->( $summary->{total}, $interval );
			}
		}

		delete( $summary->{samples} );

		$data->{summary} = $summary;
	}

	sub normalize_intervals {
		my $self     = shift;
		my $data     = shift;
		my $interval = shift;

		$mojo->app->log->debug("normalize_intervals............\n");

		# add keys that are "per second" metrics which require special handling for normalization
		my $ps_metrics = {
			kbps      => 1,
			tps       => 1,
			tps_2xx   => 1,
			tps_3xx   => 1,
			tps_4xx   => 1,
			tps_5xx   => 1,
			tps_total => 1,
		};

		if ( $data->{interval} > $interval && $data->{interval} % $interval == 0 ) {
			for my $series ( @{ $data->{series} } ) {
				for my $sample ( @{ $series->{samples} } ) {
					my $slice = $data->{interval} / $interval;

					if ( defined($sample) && !exists( $ps_metrics->{ $data->{statName} } ) ) {
						$sample = $sample / $slice;
					}

					for ( my $i = 0; $i < $slice; $i++ ) {
						push( @{ $series->{new_samples} }, $sample );
					}

				}

				$series->{samples} = delete( $series->{new_samples} );
			}

			$data->{interval} = $interval;
		}
		elsif ( $data->{interval} < $interval && $interval % $data->{interval} == 0 ) {
			for my $series ( @{ $data->{series} } ) {
				my $span    = $interval / $data->{interval};
				my $sum     = 0;
				my $counter = 0;

				for my $sample ( @{ $series->{samples} } ) {
					$counter++;

					if ( defined($sample) ) {
						$sum += $sample;
					}

					if ( $counter == $span ) {
						if ( exists( $ps_metrics->{ $data->{statName} } ) ) {
							$sum = $sum / $counter;
						}

						push( @{ $series->{new_samples} }, $sum );
						$sum     = 0;
						$counter = 0;
					}
				}

				$series->{samples} = delete( $series->{new_samples} );
			}

			$data->{interval} = $interval;
		}

	}

	sub build_summary {
		my $self        = shift;
		my $metric_type = shift;
		my $start_date  = shift;
		my $end_date    = shift;
		my $result      = shift;

		my $summary_query = $builder->summary_query();
		$mojo->app->log->debug( "summary_query #-> " . Dumper($summary_query) );

		my $response_container = $mojo->influxdb_query( $db_name, $summary_query );
		my $response           = $response_container->{'response'};
		my $content            = $response->{_content};

		my $summary;
		my $summary_content;
		my $series_count = 0;
		if ( $response->is_success() ) {
			$summary_content = decode_json($content);

			my $ib = Extensions::InfluxDB::Builder::InfluxDBBuilder->new($mojo);
			$summary = $ib->summary_response($summary_content);

			my $average = $summary->{average};
			my $total_tps = $self->calculate_total_tps( $start_date, $end_date, $average );
			if ( $metric_type =~ /kbps/ ) {

				#we divide by 8 bytes for totalBytes
				$summary->{totalBytes} = $total_tps / 8;
			}
			else {
				$summary->{totalTransactions} = $total_tps;
			}

			$result->{summary} = $summary;
			return ( SUCCESS, $result, $summary_query );
		}
		else {
			return ( ERROR, $content, undef );
		}
	}

	sub build_series {
		my $self   = shift;
		my $result = shift;

		my $series_query = $builder->series_query();
		$mojo->app->log->debug( "series_query #-> " . Dumper($series_query) );
		my $response_container = $mojo->influxdb_query( $db_name, $series_query, "pretty" );
		my $response           = $response_container->{'response'};
		my $content            = $response->{_content};

		my $series;
		if ( $response->is_success() ) {

			my $series_content = decode_json($content);
			my $ib             = Extensions::InfluxDB::Builder::InfluxDBBuilder->new($mojo);
			$series = $ib->series_response($series_content);
			my $series_node = "series";
			if ( defined($series) && ( ref($series) eq "HASH" ) ) {
				$result->{$series_node} = $series;
				my @series_values = $series->{values};
				my $series_count  = $#{ $series_values[0] };
				$result->{$series_node}{count} = $series_count;
			}
			return ( SUCCESS, $result, $series_query );
		}

		else {
			return ( ERROR, $content, undef );
		}
	}

	# Append to the incoming result hash the additional sections.
	sub build_parameters {
		my $self            = shift;
		my $result          = shift;
		my $summary_query   = shift;
		my $series_query    = shift;
		my $cachegroup_name = $mojo->param("cacheGroupName");
		my $ds_name         = $mojo->param("deliveryServiceName");
		my $metric_type     = $mojo->param("metricType");
		my $start_date      = $mojo->param("startDate");
		my $end_date        = $mojo->param("endDate");
		my $interval        = $mojo->param("interval");
		my $host_name       = $mojo->param("hostName");
		my $orderby         = $mojo->param("orderby");
		my $limit           = $mojo->param("limit");
		my $exclude         = $mojo->param("exclude");
		my $offset          = $mojo->param("offset");

		my $parent_node     = "query";
		my $parameters_node = "parameters";
		$result->{$parent_node}{$parameters_node}{deliveryServiceName} = $ds_name;
		$result->{$parent_node}{$parameters_node}{startDate}           = $start_date;
		$result->{$parent_node}{$parameters_node}{endDate}             = $end_date;
		$result->{$parent_node}{$parameters_node}{interval}            = $interval;
		$result->{$parent_node}{$parameters_node}{metricType}          = $metric_type;
		$result->{$parent_node}{$parameters_node}{orderby}             = $orderby;
		$result->{$parent_node}{$parameters_node}{limit}               = $limit;
		$result->{$parent_node}{$parameters_node}{exclude}             = $exclude;
		$result->{$parent_node}{$parameters_node}{offset}              = $offset;

		my $queries_node = "language";
		if ( defined($series_query) ) {
			$result->{$parent_node}{$queries_node}{influxdbDatabaseName} = $db_name;
			$result->{$parent_node}{$queries_node}{influxdbSeriesQuery}  = $series_query;
			$result->{$parent_node}{$queries_node}{influxdbSummaryQuery} = $summary_query;
		}

		return $result;
	}

	sub get_cdn_name_by_dsname {
		my $self = shift;
		my $dsname = shift || confess("Delivery Service name is required");

		my $cdn_name = undef;
		my $ds_id;
		my $ds_profile_id;
		my $ds = $mojo->db->resultset('Deliveryservice')->search( { xml_id => $dsname }, {} )->single();
		if ( defined($ds) ) {
			$ds_id         = $ds->id;
			$ds_profile_id = $ds->profile->id;
			my $param =
				$mojo->db->resultset('ProfileParameter')
				->search( { -and => [ profile => $ds_profile_id, 'parameter.name' => 'CDN_name' ] }, { prefetch => [ 'parameter', 'profile' ] } )->single();

			if ( defined($param) ) {
				$cdn_name = $param->parameter->value;
				return $cdn_name;
			}
		}
		return $cdn_name;

	}
}

1;
