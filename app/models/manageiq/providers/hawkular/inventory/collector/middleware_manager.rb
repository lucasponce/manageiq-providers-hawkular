require 'hawkular/hawkular_client'

module ManageIQ::Providers
  class Hawkular::Inventory::Collector::MiddlewareManager < ManagerRefresh::Inventory::Collector
    include ::Hawkular::ClientUtils

    def connection
      @connection ||= manager.connect
    end

    def resource_tree(resource_id)
      connection.inventory.resource_tree(resource_id)
    end

    def oss
      oss = []
      Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        oss.concat(resources_for("Platform Operating System #{version}"))
      end
      oss
    end

    def agents
      agents = []
      Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        agents.concat(resources_for("Hawkular Java Agent #{version}"))
      end
      agents
    end

    def eaps
      eaps = []
      Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        eaps.concat(resources_for("WildFly Server #{version}"))
      end
      eaps
    end

    def domain_servers
      domains = []
      Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        domains.concat(resources_for("Domain WildFly Server #{version}"))
      end
      domains
    end

    def deployments
      deployments = []
      Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        deployments.concat(resources_for("Deployment #{version}"))
      end
      deployments
    end

    def subdeployments
      subdeployments = []
      Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        subdeployments.concat(resources_for("SubDeployment #{version}"))
      end
      subdeployments
    end

    def host_controllers
      host_controllers = []
      Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        host_controllers.concat(resources_for("Host Controller #{version}"))
      end
      host_controllers
    end

    def domains
      domains = []
      Hawkular::MiddlewareManager::SUPPORTED_VERSIONS.each do |version|
        domains.concat(resources_for("Domain Host #{version}"))
      end
      domains
    end

    def child_resources(resource_id, recursive = false)
      manager.child_resources(resource_id, recursive)
    end

    def raw_availability_data(metrics, time)
      connection.prometheus.query(:metrics => metrics, :time => time)
    rescue => err
      $mw_log.error(err)
      nil
    end

    private

    def resources_for(resource_type)
      connection.inventory.resources_for_type(resource_type)
    end
  end
end
