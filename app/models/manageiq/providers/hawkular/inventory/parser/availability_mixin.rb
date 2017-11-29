module ManageIQ::Providers::Hawkular::Inventory::Parser
  module AvailabilityMixin
    protected

    def fetch_availabilities_for(resources, collection, metric_type_id)
      metric_id_to_resources = resources.reject { |r| r.metrics_by_type(metric_type_id).empty? }.group_by do |resource|
        resource.metrics_by_type(metric_type_id).first.hawkular_id
      end
      unless metric_id_to_resources.empty?
        found_availabilities = []
        collector.raw_availability_data(metric_id_to_resources.keys, :limit => 1, :order => 'DESC').each do |availability|
          next unless metric_id_to_resources.key?(availability['id'])
          found_availabilities << availability['id']
          metric_id_to_resources.fetch(availability['id']).each do |hawkular_resource|
            resource = collection.find_by(:ems_ref => hawkular_resource.id)
            yield(resource, availability)
          end
        end
        # Provide means to notify if there is a resource without the avail metric
        ems_ref_of_unknown_avail = metric_id_to_resources.keys.to_set.subtract(found_availabilities).to_a
        ems_ref_of_unknown_avail.each do |availability_id|
          metric_id_to_resources.fetch(availability_id).each do |hawkular_resource|
            yield(collection.find_by(:ems_ref => hawkular_resource.id), nil)
          end
        end
      end
    end

    def process_availability(availability, translation = {})
      translation.fetch(availability.try(:[], 'value').try(:downcase), 'Unknown')
    end
  end
end
