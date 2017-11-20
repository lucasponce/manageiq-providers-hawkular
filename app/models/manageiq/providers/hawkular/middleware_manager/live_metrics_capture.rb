module ManageIQ::Providers
  class Hawkular::MiddlewareManager::LiveMetricsCapture
    include Vmdb::Logging

    class MetricValidationError < RuntimeError; end

    ONE_HOUR = 60 * 60
    ONE_DAY = 60 * 60 * 24
    ONE_WEEK = ONE_DAY * 7

    def initialize(target)
      @target = target
      @ems = @target.ext_management_system
      @prometheus_client = @ems.prometheus_client
      @included_children = @target.included_children
      @supported_metrics = @target.supported_metrics
    end

    def fetch_metrics_available
      _log.info("DELETEME fetch_metrics_available ⁻ BEGIN")
      resource = @included_children ? @ems.resource_tree(@target.ems_ref) : @ems.resource(@target.ems_ref)
      resource.metrics(!!@included_children)
              .select { |metric| @supported_metrics[@target.live_metrics_type].key?(metric.name) }
              .collect do |metric|
                metric_hash = metric.to_h
                metric_hash['name'] = @supported_metrics[@target.live_metrics_type][metric.name]
                metric_hash
              end
              .to_a
    end

    def collect_stats_metrics(metrics, start_time, end_time, interval)
      _log.info("DELETEME collect_stats_metrics metrics #{metrics} metrics.empty? #{metrics.empty?}")
      return [] if metrics.empty?
      starts = start_time.to_i
      ends = (end_time + interval).to_i + 1
      step = "#{interval}s"
      results = @prometheus_client.query_range(:metrics => metrics,
                                               :starts  => starts,
                                               :ends    => ends,
                                               :step    => step)
      _log.info("DELETEME collect_stats_metrics results #{results}")
      results
    end

    def collect_live_metrics(metrics, start_time, end_time, interval)
      _log.info("DELETEME collect_live_metrics start_time #{start_time} end_time #{end_time} interval #{interval}")
      raw_stats = collect_stats_metrics(metrics, start_time, end_time, interval)
      process_stats(raw_stats)
    end

    def collect_report_metrics(report_cols, start_time, end_time, interval)
      _log.info("DELETEME collect_report_metrics start_time #{start_time} end_time #{end_time} interval #{interval}")
      # TODO We might want to update this in the future as we don't have out of the box min/max/samples data but perhaps
      # TODO it is not necessary now for these reports
      # TODO In the future we might need support from inventory for customized reports
      filtered = @target.metrics_available.select { |metric| report_cols.nil? || report_cols.include?(metric['name']) }
      report_metrics = collect_live_metrics(filtered, start_time, end_time, interval)
      _log.info("DELETEME collect_report_metrics report_metrics #{report_metrics}")
      report_metrics
    end

    def process_stats(raw_stats)
      _log.info("DELETEME process_stats raw_stats #{raw_stats}")
      processed = Hash.new { |h, k| h[k] = {} }
      raw_stats.each do |raw_data|
        next unless raw_data['values']
        raw_data['values'].each do |datapoint|
          timestamp = datapoint.first
          value = datapoint.last.to_f
          processed.store_path(timestamp, raw_data['metric']['name'], value)
        end
      end
      _log.info("DELETEME process_stats processed #{processed}")
      processed
    end

    def first_and_last_capture(interval_name = "realtime")
      _log.info("DELETEME first_and_last_capture #{interval_name}")
      now = Time.new.utc
      one_week_before = now - ONE_WEEK
      last = now
      first = now
      results = @prometheus_client.up_time(:feed_id => @target.feed,
                                           :starts  => one_week_before.to_i,
                                           :ends    => now.to_i,
                                           :step    => '3600m')
      _log.info("DELETEME first_and_last_capture results #{results}")
      if results.empty?
        one_day_before = now - ONE_DAY
        results = @prometheus_client.up_time(:feed_id => @target.feed,
                                             :starts  => one_day_before.to_i,
                                             :ends    => now.to_i,
                                             :step    => '60m')
      end
      unless results.empty?
        datapoint = results.first
        _log.info("DELETEME first_and_last_capture datapoint #{datapoint}")
        first = Time.at(datapoint.first.to_i)
      end
      if interval_name == "hourly"
        first = (now - first) > 1.hour ? first : nil
      end
      _log.info("DELETEME first_and_last_capture [first, last] #{[first, last]}")
      [first, last]
    end
  end

  module Hawkular::MiddlewareManager::LiveMetricsCaptureMixin
    def metrics_capture
      @metrics_capture ||= ManageIQ::Providers::Hawkular::MiddlewareManager::LiveMetricsCapture.new(self)
      _log.info("DELETEME metrics_capture self #{self}")
      _log.info("DELETEME metrics_capture @metrics_capture #{@metrics_capture}")
      _log.info("DELETEME metrics_capture @metrics_capture.methods #{@metrics_capture.methods}")
      @metrics_capture
    end
  end
end
