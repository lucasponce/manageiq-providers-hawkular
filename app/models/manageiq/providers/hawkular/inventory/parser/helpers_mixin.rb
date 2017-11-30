module ManageIQ::Providers::Hawkular::Inventory::Parser
  module HelpersMixin
    protected

    def parse_base_item(item, inventory_object)
      inventory_object.nativeid = item.id
      inventory_object[:properties] = item.config if item.respond_to?(:config)
      inventory_object[:feed] = item.feed if item.respond_to?(:feed)
    end
  end
end
