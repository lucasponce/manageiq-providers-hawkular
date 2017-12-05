module ManageIQ::Providers
  class Hawkular::MiddlewareManager::LiveMetricsCapture
    class MetricValidationError < RuntimeError; end

    ONE_HOUR = 60 * 60
    ONE_DAY = 60 * 60 * 24
    ONE_WEEK = ONE_DAY * 7

    def initialize(target)
      @target = target
      @ems = @target.ext_management_system
      @included_children = @target.included_children
      @supported_metrics = @target.supported_metrics
    end

    def fetch_metrics_available
      resource = @included_children ? @ems.resource_tree(@target.ems_ref) : @ems.resource(@target.ems_ref)
      resource.metrics(!!@included_children)
              .select { |metric| @supported_metrics[@target.live_metrics_type].key?(metric.name) }
              .collect do |metric|
                metric_hash = metric.to_h
                metric_hash['name'] = @supported_metrics[@target.live_metrics_type][metric.name]
                metric_hash
              end
              .to_a
    rescue => err
      $mw_log.error(err)
      []
    end

    def collect_stats_metrics(metrics, start_time, end_time, interval)
      return [] if metrics.empty?
      starts = start_time.to_i
      ends = (end_time + interval).to_i + 1
      step = "#{interval}s"
      results = @ems.prometheus_client.query_range(:metrics => metrics,
                                                   :starts  => starts,
                                                   :ends    => ends,
                                                   :step    => step)
      $mw_log.debug("collect_stats_metrics metrics: #{metrics} results: #{results}")
      results
    end

    def collect_live_metrics(metrics, start_time, end_time, interval)
      raw_stats = collect_stats_metrics(metrics, start_time, end_time, interval)
      process_stats(raw_stats)
    end

    def collect_report_metrics(report_cols, start_time, end_time, interval)
      filtered = @target.metrics_available.select { |metric| report_cols.nil? || report_cols.include?(metric['name']) }
      collect_live_metrics(filtered, start_time, end_time, interval)
    end

    def process_stats(raw_stats)
      processed = Hash.new { |h, k| h[k] = {} }
      raw_stats.each do |raw_data|
        next unless raw_data['values']
        raw_data['values'].each do |datapoint|
          timestamp = datapoint.first
          value = datapoint.last.to_f
          processed.store_path(timestamp, raw_data['metric']['name'], value)
        end
      end
      processed
    end

    def first_and_last_capture(interval_name = "realtime")
      now = Time.new.utc
      one_week_before = now - ONE_WEEK
      last = now
      first = now
      results = @ems.prometheus_client.up_time(:feed_id => @target.feed,
                                               :starts  => one_week_before.to_i,
                                               :ends    => now.to_i,
                                               :step    => '1440m')
      if results.empty?
        one_day_before = now - ONE_DAY
        results = @ems.prometheus_client.up_time(:feed_id => @target.feed,
                                                 :starts  => one_day_before.to_i,
                                                 :ends    => now.to_i,
                                                 :step    => '60m')
      end
      unless results.empty?
        datapoint = results.first
        first = Time.at(datapoint.first.to_i).utc
      end
      if interval_name == "hourly"
        first = (now - first) > 1.hour ? first : nil
      end
      $mw_log.debug("first_and_last_capture [first, last] #{[first, last]}")
      [first, last]
    rescue => err
      $mw_log.error(err)
      [nil, nil]
    end
  end
end
