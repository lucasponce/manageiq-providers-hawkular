module ManageIQ::Providers::Hawkular
  class Builder
    def self.build_inventory(ems, target)
      case target
      when ::ManageIQ::Providers::MiddlewareManager
        collector = Inventory::Collector::MiddlewareManager.new(ems, target)
        persister = Inventory::Persister::MiddlewareManager.new(ems, target)
        parser = [
          Inventory::Parser::MiddlewareServers.new,
          Inventory::Parser::MiddlewareDomains.new,
          Inventory::Parser::MiddlewareDomainServers.new,
          Inventory::Parser::MiddlewareServerEntities.new
        ]
      when ::ManageIQ::Providers::Hawkular::Inventory::AvailabilityUpdates
        collector = Inventory::Collector::AvailabilityUpdates.new(ems, target)
        persister = Inventory::Persister::AvailabilityUpdates.new(ems, target)
        parser = Inventory::Parser::AvailabilityUpdates.new
      end

      ManagerRefresh::Inventory.new(persister, collector, parser)
    end
  end
end
