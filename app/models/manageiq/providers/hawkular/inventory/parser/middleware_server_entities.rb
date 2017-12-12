module ManageIQ::Providers::Hawkular::Inventory::Parser
  class MiddlewareServerEntities < ManagerRefresh::Inventory::Parser
    include ManageIQ::Providers::Hawkular::Inventory::Parser::HelpersMixin
    include ManageIQ::Providers::Hawkular::Inventory::Parser::AvailabilityMixin
    include ::Hawkular::ClientUtils

    SUPPORTED_ENTITIES = ['Deployment', 'SubDeployment', 'Datasource', 'JMS Queue', 'JMS Topic'].freeze

    def initialize
      @supported_types = []
      @supported_deployments = []
      @supported_subdeployments = []
      @supported_datasources = []
      ManageIQ::Providers::Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        SUPPORTED_ENTITIES.each { |entity| @supported_types << "#{entity} #{version}" }
        %w(Deployment SubDeployment).each { |deployment| @supported_deployments << "#{deployment} #{version}" }
        @supported_subdeployments << "SubDeployment #{version}"
        @supported_datasources << "Datasource #{version}"
      end
    end

    def parse
      fetch_server_entities
      fetch_deployment_availabilities
    end

    protected

    def fetch_server_entities
      persister.middleware_servers.each do |eap|
        eap_tree = collector.resource_tree(eap.ems_ref)
        eap_tree.children(true).each do |child|
          next unless @supported_types.include?(child.type.id)
          process_server_entity(eap, child)
        end
      end
    end

    def fetch_deployment_availabilities
      collection = persister.middleware_deployments
      fetch_availabilities_for(collector.deployments, collection, collection.model_class::AVAIL_TYPE_ID) do |deployment, availability|
        deployment.status = process_deployment_availability(availability)
      end
      subdeployments_by_deployment_id = collector.subdeployments.group_by(&:parent_id)
      subdeployments_by_deployment_id.keys.each do |parent_id|
        deployment = collection.find_by(:ems_ref => parent_id)
        subdeployments_by_deployment_id.fetch(parent_id).each do |collected_subdeployment|
          subdeployment = collection.find_by(:ems_ref => collected_subdeployment.id)
          subdeployment.status = deployment.status
        end
      end
    end

    def process_server_entity(server, entity)
      if @supported_deployments.include?(entity.type.id)
        inventory_object = persister.middleware_deployments.find_or_build(entity.id)
        parse_deployment(entity, inventory_object)
      elsif @supported_datasources.include?(entity.type.id)
        inventory_object = persister.middleware_datasources.find_or_build(entity.id)
        parse_datasource(entity, inventory_object)
      else
        inventory_object = persister.middleware_messagings.find_or_build(entity.id)
        parse_messaging(entity, inventory_object)
      end

      inventory_object.middleware_server = persister.middleware_servers.lazy_find(server.ems_ref)
      inventory_object.middleware_server_group = server.middleware_server_group if inventory_object.respond_to?(:middleware_server_group=)
    end

    def parse_deployment(deployment, inventory_object)
      parse_base_item(deployment, inventory_object)
      inventory_object.name = deployment.name
      if @supported_subdeployments.include?(deployment.type.id)
        inventory_object.properties[inventory_object.model_class::PARENT_DEPLOYMENT_ID_PROPERTY] = deployment.parent_id
      end
    end

    def parse_messaging(messaging, inventory_object)
      parse_base_item(messaging, inventory_object)
      inventory_object.name = messaging.name

      inventory_object.messaging_type = messaging.type.id
      inventory_object.properties = messaging.config.except('Username', 'Password')
    end

    def parse_datasource(datasource, inventory_object)
      parse_base_item(datasource, inventory_object)
      inventory_object.name = datasource.name

      inventory_object.properties = datasource.config.except('Username', 'Password')
    end

    def process_deployment_availability(availability = nil)
      return 'Unknown' if availability.nil? || availability.first.nil?
      if availability.first['value'] && availability.first['value'][1] == '1'
        'Enabled'
      else
        'Disabled'
      end
    end
  end
end
