module ManageIQ::Providers::Hawkular::Inventory::Parser
  module AvailabilityMixin
    protected

    def fetch_availabilities_for(inventory_entities, entities, metric_name)
      inventory_entities.each do |inventory_entity|
        entity = entities.find_by(:ems_ref => inventory_entity.id)
        availability = nil
        availability_metric = filter_metric(inventory_entity, metric_name)
        if availability_metric
          availability = collector.raw_availability_data([availability_metric.to_h], Time.now.to_i)
        end
        yield(entity, availability)
      end
    end

    def filter_metric(inventory_item, metric_name)
      selected_metric = nil
      inventory_item.metrics.each do |metric|
        next unless metric.name.eql?(metric_name)
        selected_metric = metric
        break
      end
      selected_metric
    end
  end
end
