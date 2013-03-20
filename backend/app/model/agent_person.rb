require_relative 'agent_manager'
require_relative 'name_person'
require_relative 'recordable_cataloging'
require_relative 'notes'

class AgentPerson < Sequel::Model(:agent_person)

  include ASModel
  include ExternalDocuments
  include AgentManager::Mixin
  include RecordableCataloging
  include Notes

  corresponds_to JSONModel(:agent_person)

  register_agent_type(:jsonmodel => :agent_person,
                      :name_type => :name_person,
                      :name_model => NamePerson)
  

end