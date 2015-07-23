package Extensions::Delegate::CacheStatistics;
#
# Copyright 2011-2014, Comcast Corporation. This software and its contents are
# Comcast confidential and proprietary. It cannot be used, disclosed, or
# distributed without Comcast's prior written permission. Modification of this
# software is only allowed at the direction of Comcast Corporation. All allowed
# modifications must be provided to Comcast Corporation.
#

# JvD Note: you always want to put Utils as the first use.
use UI::Utils;
use Mojo::Base 'Mojolicious::Controller';
use Data::Dumper;
use JSON;
use constant SUCCESS => 0;
use constant ERROR   => 1;
use Utils::Helper::Extensions;
use Extensions::InfluxDB::Builder::CacheStatsBuilder;
use Extensions::InfluxDB::Builder::DeliveryServiceStatsBuilder;
Utils::Helper::Extensions->use;

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
		name        => "CacheStatistics",
		version     => "0.01",
		info_url    => "",
		description => "Cache Statistics Stub",
		isactive    => 1,
		script_file => "Extensions::Delegate::CacheStatistics",
	};
}

sub get_usage_overview {
	my $self = shift;

	$builder = new Extensions::InfluxDB::Builder::CacheStatsBuilder();
	my $query = $builder->usage_overview_maxkbps_query();
	$mojo->app->log->debug( "query #-> " . $query );

	my $response_container = $mojo->influxdb_query( $db_name, $query );
	my $response           = $response_container->{'response'};
	my $json_content       = $response->{_content};

	my $result;
	my $summary;
	my $content;
	if ( $response->is_success() ) {
		$content = decode_json($json_content);
		$mojo->app->log->debug( "content #-> " . Dumper($content) );
		$result->{maxKbps} = $content->{results}[0]{series}[0]->{values}[0][1];

	}
	else {
		return ( ERROR, $content, undef );
	}

	$builder = new Extensions::InfluxDB::Builder::DeliveryServiceStatsBuilder();
	$query   = $builder->usage_overview_tps_query();
	$mojo->app->log->debug( "query #-> " . $query );
	$response_container = $mojo->influxdb_query( $db_name, $query );
	$response           = $response_container->{'response'};
	$json_content       = $response->{_content};
	if ( $response->is_success() ) {
		$content = decode_json($json_content);
		$mojo->app->log->debug( "content #-> " . Dumper($content) );
		$result->{tps} = $content->{results}[0]{series}[0]->{values}[0][1];
	}
	else {
		return ( ERROR, $content, undef );
	}

	return ( SUCCESS, $result, $query );
}

#TODO: drichardson
#      - Add required fields validation see lib/API/User.pm based on Validate::Tiny
#      - Verify how much can be refactored after cache_stats value grouping is complete.
sub get_stats {
	my $self        = shift;
	my $cdn_name    = $mojo->param('cdnName');
	my $metric_type = $mojo->param('metricType');
	my $server_type = $mojo->param('serverType');
	my $start_date  = $mojo->param('startDate');
	my $end_date    = $mojo->param('endDate');
	my $interval    = $mojo->param('interval') || "60s";    # Valid interval examples 10m (minutes), 10s (seconds), 1h (hour)
	my $exclude     = $mojo->param('exclude');
	my $orderby     = $mojo->param('orderby');
	my $limit       = $mojo->param('limit');
	my $offset      = $mojo->param('offset');

	# Build the summary section
	$builder = new Extensions::InfluxDB::Builder::CacheStatsBuilder(
		{
			series_name => $metric_type,
			cdn_name    => $cdn_name,
			start_date  => $start_date,
			end_date    => $end_date,
			interval    => $interval,
			orderby     => $orderby,
			limit       => $limit,
			offset      => $offset
		}
	);

	my $rc     = 0;
	my $result = ();
	my $summary_query;

	my $include_summary = ( defined($exclude) && $exclude =~ /summary/ ) ? 0 : 1;
	if ($include_summary) {
		( $rc, $result, $summary_query ) = $self->build_summary($result);
	}

	if ( $rc == SUCCESS ) {
		my $include_series = ( defined($exclude) && $exclude =~ /series/ ) ? 0 : 1;

		my $series_query;
		if ($include_series) {
			( $rc, $result, $series_query ) = $self->build_series($result);
		}
		if ( $rc == SUCCESS ) {
			$result = $self->build_parameters( $result, $summary_query, $series_query );
			return ( SUCCESS, $result );
		}
		else {
			return ( ERROR, $result );
		}
	}
	else {
		return ( ERROR, $result );
	}

}

sub build_summary {
	my $self   = shift;
	my $result = shift;

	my $summary_query = $builder->summary_query();
	$mojo->app->log->debug( "summary_query #-> " . $summary_query );

	my $response_container = $mojo->influxdb_query( $db_name, $summary_query );
	my $response           = $response_container->{'response'};
	my $content            = $response->{_content};

	my $summary;
	my $summary_content;
	if ( $response->is_success() ) {
		$summary_content = decode_json($content);
		$mojo->app->log->debug( "summary_content #-> " . Dumper($summary_content) );
		$summary = Extensions::InfluxDB::Builder::InfluxDBBuilder->summary_response($summary_content);
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
	$mojo->app->log->debug( "series_query #-> " . $series_query );
	my $response_container = $mojo->influxdb_query( $db_name, $series_query );
	my $response           = $response_container->{'response'};
	my $content            = $response->{_content};

	my $series;
	if ( $response->is_success() ) {
		my $series_content = decode_json($content);
		$series = Extensions::InfluxDB::Builder::InfluxDBBuilder->series_response($series_content);
		my $series_node = "series";
		if ( defined($series) && ( keys $series ) ) {
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

sub build_parameters {
	my $self          = shift;
	my $result        = shift;
	my $summary_query = shift;
	my $series_query  = shift;

	my $cdn_name    = $mojo->param('cdnName');
	my $metric_type = $mojo->param('metricType');
	my $server_type = $mojo->param('serverType');
	my $start_date  = $mojo->param('startDate');
	my $end_date    = $mojo->param('endDate');
	my $interval    = $mojo->param('interval') || "1m";    # Valid interval examples 10m (minutes), 10s (seconds), 1h (hour)
	my $exclude     = $mojo->param('exclude');
	my $limit       = $mojo->param('limit');
	my $offset      = $mojo->param('offset');
	my $orderby     = $mojo->param('orderby');

	my $parent_node     = "query";
	my $parameters_node = "parameters";
	$result->{$parent_node}{$parameters_node}{cdnName}    = $cdn_name;
	$result->{$parent_node}{$parameters_node}{startDate}  = $start_date;
	$result->{$parent_node}{$parameters_node}{endDate}    = $end_date;
	$result->{$parent_node}{$parameters_node}{interval}   = $interval;
	$result->{$parent_node}{$parameters_node}{metricType} = $metric_type;
	$result->{$parent_node}{$parameters_node}{orderby}    = $orderby;
	$result->{$parent_node}{$parameters_node}{limit}      = $limit;
	$result->{$parent_node}{$parameters_node}{offset}     = $offset;

	my $queries_node = "language";
	$result->{$parent_node}{$queries_node}{influxdbDatabaseName} = $db_name;
	$result->{$parent_node}{$queries_node}{influxdbSeriesQuery}  = $series_query;
	$result->{$parent_node}{$queries_node}{influxdbSummaryQuery} = $summary_query;

	return $result;
}

1;
