module ManageIQ::Providers
  class Hawkular::MiddlewareManager::AlertProfileManager
    require 'hawkular/hawkular_client'
    require 'digest/sha1'

    def initialize(ems)
      @ems = ems
      @alerts_client = ems.alerts_client
    end

    def process_alert_profile(operation, miq_alert_profile)
      profile_id = miq_alert_profile[:id]
      old_alerts_ids = miq_alert_profile[:old_alerts_ids]
      new_alerts_ids = miq_alert_profile[:new_alerts_ids]
      old_assignments_ids = miq_alert_profile[:old_assignments_ids]
      new_assignments_ids = miq_alert_profile[:new_assignments_ids]
      case operation
      when :update_alerts
        update_alerts(profile_id, old_alerts_ids, new_alerts_ids, old_assignments_ids)
      when :update_assignments
        update_assignments(profile_id, old_alerts_ids, old_assignments_ids, new_assignments_ids)
      end
    end

    def update_alerts(profile_id, old_alerts_ids, new_alerts_ids, old_assignments_ids)
      unless old_assignments_ids.empty?
        to_remove_alerts_ids = old_alerts_ids - new_alerts_ids
        to_add_alerts_ids = new_alerts_ids - old_alerts_ids
        retrieve_hawkular_group_triggers(to_remove_alerts_ids).each do |group_trigger|
          unassign_members(group_trigger, profile_id, old_assignments_ids)
        end
        retrieve_hawkular_group_triggers(to_add_alerts_ids).each do |group_trigger|
          assign_members(group_trigger, profile_id, old_assignments_ids)
        end
      end
    end

    def update_assignments(profile_id, old_alerts_ids, old_assignments_ids, new_assignments_ids)
      to_unassign_ids = old_assignments_ids - new_assignments_ids
      to_assign_ids = new_assignments_ids - old_assignments_ids
      if to_unassign_ids.any? || to_assign_ids.any?
        retrieve_hawkular_group_triggers(old_alerts_ids).each do |group_trigger|
          unassign_members(group_trigger, profile_id, to_unassign_ids) unless to_unassign_ids.empty?
          assign_members(group_trigger, profile_id, to_assign_ids) unless to_assign_ids.empty?
        end
      end
    end

    def unassign_members(group_trigger, profile_id, members_ids)
      context, profiles = unassign_members_context(group_trigger, profile_id)
      group_trigger.context = context
      @alerts_client.update_group_trigger(group_trigger)
      if profiles.empty?
        members_ids.each do |member_id|
          @alerts_client.orphan_member("#{group_trigger.id}-#{member_id}")
          @alerts_client.delete_trigger("#{group_trigger.id}-#{member_id}")
        end
      end
    end

    def unassign_members_context(group_trigger, profile_id)
      context = group_trigger.context.nil? ? {} : group_trigger.context
      profiles = context['miq.alert_profiles'].nil? ? [] : context['miq.alert_profiles'].split(",")
      profiles -= [profile_id.to_s]
      context['miq.alert_profiles'] = profiles.uniq.join(",")
      [context, profiles]
    end

    def assign_members(group_trigger, profile_id, members_ids)
      group_trigger.context = assign_members_context(group_trigger, profile_id)
      @alerts_client.update_group_trigger(group_trigger)
      members = @alerts_client.list_members group_trigger.id
      current_members_ids = members.collect(&:id)
      members_ids.each do |member_id|
        next if current_members_ids.include?("#{group_trigger.id}-#{member_id}")
        create_new_member(group_trigger, member_id)
      end
    end

    def assign_members_context(group_trigger, profile_id)
      context = group_trigger.context.nil? ? {} : group_trigger.context
      profiles = context['miq.alert_profiles'].nil? ? [] : context['miq.alert_profiles'].split(",")
      profiles.push(profile_id.to_s)
      context['miq.alert_profiles'] = profiles.uniq.join(",")
      context
    end

    def create_new_member(group_trigger, member_id)
      resource = MiddlewareServer.find(member_id)
      create_new_member_from_resource(group_trigger, resource)
    end

    def create_new_member_from_resource(group_trigger, resource)
      new_member = ::Hawkular::Alerts::Trigger::GroupMemberInfo.new
      new_member.group_id = group_trigger.id
      member_trigger_id = "#{group_trigger.id}-#{resource.id}"
      new_member.member_id = member_trigger_id
      new_member.member_name = "#{group_trigger.name} for #{resource.name}"
      # Note, the dataId must be unique to the member trigger but can not be the member trigger id because
      # that is not allowed by hAlerts (will cause infinite event chaining).  So, use a digest.
      new_member.data_id_map = { 'group_data_id' => Digest::SHA1.hexdigest(member_trigger_id) }
      new_member.member_context = calculate_member_context(resource, group_trigger.conditions[0].expression)

      @alerts_client.create_member_trigger(new_member)
    end

    def calculate_member_context(resource, expression)
      context = {}
      context['resource_path'] = resource.ems_ref.to_s
      resource.metrics_available.each do |metric|
        ts = "$TS(#{metric['displayName']})"
        family_ts = "$FAMILY_TS(#{metric['displayName']})"
        context[ts] = metric['expression'] if (expression.include?(ts))
        context[family_ts] = metric['expression'].match("#{metric['family']}{.*}") if (expression.include?(family_ts))
      end
      context
    end

    private

    def retrieve_hawkular_group_triggers(alert_ids)
      alert_ids.map do |item|
        trigger_id = ::ManageIQ::Providers::Hawkular::MiddlewareManager::
          AlertManager.resolve_hawkular_trigger_id(:ems => @ems, :alert => item, :alerts_client => @alerts_client)
        @alerts_client.get_single_trigger(trigger_id, true)
      end
    end
  end
end
