require 'asconstants'
require 'memoryleak'
require 'search'

class ApplicationController < ActionController::Base
  protect_from_forgery

  helper :all

  rescue_from ArchivesSpace::SessionGone, :with => :destroy_user_session
  rescue_from ArchivesSpace::SessionExpired, :with => :destroy_user_session
  rescue_from RecordNotFound, :with => :render_404
  rescue_from AccessDeniedException, :with => :render_403

  # Allow overriding of templates via the local folder(s)
  if not ASUtils.find_local_directories.blank?
    ASUtils.find_local_directories.map{|local_dir| File.join(local_dir, 'frontend', 'views')}.reject { |dir| !Dir.exists?(dir) }.each do |template_override_directory|
      prepend_view_path(template_override_directory)
    end
  end

  # Note: This should be first!
  before_filter :store_user_session

  before_filter :determine_browser_support

  before_filter :refresh_permissions

  before_filter :refresh_preferences

  before_filter :load_repository_list

  before_filter :unauthorised_access

  def self.permission_mappings
    Array(@permission_mappings)
  end

  def self.can_access?(context, method)
    permission_mappings.each do |permission, actions|
      if actions.include?(method) && !session_can?(context, permission)
        return false
      end
    end

    return true
  end


  def self.set_access_control(permission_mappings)
    @permission_mappings = permission_mappings

    skip_before_filter :unauthorised_access, :only => Array(permission_mappings.values).flatten.uniq

    permission_mappings.each do |permission, actions|
      next if permission === :public

      before_filter(:only => Array(actions)) {|c| user_must_have(permission)}
    end
  end

  protected

  def inline?
    params[:inline] === "true"
  end


  # Perform the common create/update logic for our various CRUD controllers:
  #
  #  * Take user parameters and massage them a bit
  #  * Grab the existing instance of our JSONModel
  #  * Update it from the parameters
  #  * If all looks good, send the user off to their next adventure
  #  * Otherwise, throw the form back with warnings/errors
  #
  def handle_crud(opts)
    begin
      # Start with the JSONModel object provided, or an empty one if none was
      # given.  Update it from the user's parameters
      model = opts[:model] || JSONModel(opts[:instance])
      obj = opts[:obj] || model.new

      obj.instance_data[:find_opts] = opts[:find_opts] if opts.has_key? :find_opts

      # Param validations that don't have to do with the JSON validator
      opts[:params_check].call(obj, params) if opts[:params_check]

      instance = cleanup_params_for_schema(params[opts[:instance]], model.schema)

      if opts[:replace] || opts[:replace].nil?
        obj.replace(instance)
      else
        obj.update(instance)
      end

      # Make the updated object available to templates
      instance_variable_set("@#{opts[:instance]}".intern, obj)

      if not params.has_key?(:ignorewarnings) and not obj._warnings.empty?
        # Throw the form back to the user to confirm warnings.
        instance_variable_set("@exceptions".intern, obj._exceptions)
        return opts[:on_invalid].call
      end

      if obj._exceptions[:errors]
        instance_variable_set("@exceptions".intern, obj._exceptions)
        return opts[:on_invalid].call
      end

      if opts.has_key?(:save_opts)
        id = obj.save(opts[:save_opts])
      elsif opts[:instance] == :user and !params['user']['password'].blank?
        id = obj.save(:password => params['user']['password'])
      else
        id = obj.save
      end
      opts[:on_valid].call(id)
    rescue ConflictException
      instance_variable_set(:"@record_is_stale".intern, true)
      opts[:on_invalid].call
    rescue JSONModel::ValidationException => e
      # Throw the form back to the user to display error messages.
      instance_variable_set("@exceptions".intern, obj._exceptions)
      opts[:on_invalid].call
    end
  end


  def handle_merge(victims, target_uri, merge_type, extra_params = {})
    request = JSONModel(:merge_request).new
    request.target = {'ref' => target_uri}
    request.victims = Array.wrap(victims).map { |victim| { 'ref' => victim  } }

    begin
      request.save(:record_type => merge_type)
      flash[:success] = I18n.t("#{merge_type}._frontend.messages.merged")

      resolver = Resolver.new(target_uri)
      redirect_to(resolver.view_uri)
    rescue ValidationException => e
      flash[:error] = e.errors.to_s
      redirect_to({:action => :show, :id => params[:id]}.merge(extra_params))
    rescue RecordNotFound => e
      flash[:error] = I18n.t("errors.error_404")
      redirect_to({:action => :show, :id => params[:id]}.merge(extra_params))
    end
  end


  def handle_accept_children(target_jsonmodel)
    response = JSONModel::HTTP.post_form(target_jsonmodel.uri_for(params[:id]) + "/accept_children",
                                         "children[]" => params[:children],
                                         "position" => params[:index].to_i)




    if response.code == '200'
      render :json => {
        :position => params[:index].to_i
      }
    else
      raise "Error setting parent of archival objects: #{response.body}"
    end
  end


  def find_opts
    {
      "resolve[]" => ["subjects", "related_resources", "linked_agents",
                      "revision_statements", 
                      "container_locations", "digital_object", "classifications",
                      "related_agents", "resource", "parent", "creator",
                      "linked_instances", "linked_records", "related_accessions",
                      "linked_events", "linked_events::linked_records",
                      "linked_events::linked_agents",
                      "top_container", "container_profile", "location_profile",
                      "owner_repo"]
    }
  end

  def user_is_global_admin?
    session['user'] and session['user'] == "admin"
  end


  def user_must_have(permission)
    unauthorised_access if !session['user'] || !user_can?(permission)
  end


  def user_needs_to_be_a_user
    unauthorised_access if not session['user']
  end
  
  def user_needs_to_be_a_user_manager
    unauthorised_access if not user_can? 'manage_users'
  end
  
  def user_needs_to_be_a_user_manager_or_new_user
    unauthorised_access if session['user'] and not user_can? 'manage_users'
  end

  def user_needs_to_be_global_admin
    unauthorised_access if not user_is_global_admin?
  end

  helper_method :user_prefs
  def user_prefs
    session[:preferences] || self.class.user_preferences(session)
  end

  def user_repository_cookie
    cookies[user_repository_cookie_key]
  end

  def user_repository_cookie_key
    "#{AppConfig[:cookie_prefix]}_#{session[:user]}_repository"
  end

  def set_user_repository_cookie(repository_uri)
    cookies[user_repository_cookie_key] = repository_uri
  end


  def self.session_repo(session, repo)
    session[:repo] = repo
    session[:repo_id] = JSONModel(:repository).id_for(repo)
    self.user_preferences(session)
  end


  def self.user_preferences(session)
    session[:last_preference_refresh] = Time.now.to_i
    if session[:repo_id]
      session[:preferences] = JSONModel::HTTP::get_json("/repositories/#{session[:repo_id]}/current_preferences")['defaults']
    else
      session[:preferences] = JSONModel::HTTP::get_json("/current_global_preferences")['defaults']
    end
  end


  helper_method :user_can?
  def user_can?(permission, repository = nil)
    self.class.session_can?(self, permission, repository)
  end


  def self.session_can?(context, permission, repository = nil)
    repository ||= context.session[:repo]

    return false if !context.session || !context.session[:user]

    permissions_s = context.send(:cookies).signed[:archivesspace_permissions]

    if permissions_s
      permissions = ASUtils.json_parse(permissions_s)
    else
      return false
    end

    (Permissions.user_can?(permissions, repository, permission) ||
     Permissions.user_can?(permissions, ASConstants::Repository.GLOBAL, permission))
  end


  helper_method :current_vocabulary
  def current_vocabulary
    MemoryLeak::Resources.get(:vocabulary).first.to_hash
  end


  private

  def destroy_user_session(exception)
    Thread.current[:backend_session] = nil
    Thread.current[:repo_id] = nil

    reset_session

    @message = exception.message
    return render :template => "401", :layout => nil if inline?

    flash[:error] = exception.message
    redirect_to :controller => :welcome, :action => :index, :login => true
  end


  def store_user_session
    Thread.current[:backend_session] = session[:session]
    JSONModel::set_repository(session[:repo_id])
  end


  def load_repository_list
    @repositories = MemoryLeak::Resources.get(:repository).find_all do |repository|
      user_can?('view_repository', repository.uri) || user_can?('manage_repository', repository.uri)
    end

    # Make sure the user's selected repository still exists.
    if session[:repo] && !@repositories.any?{|repo| repo.uri == session[:repo]}
      session.delete(:repo)
      session.delete(:repo_id)
    end

    if not session[:repo] and not @repositories.empty?
      if user_repository_cookie
        if @repositories.any?{|repo| repo.uri == user_repository_cookie}
          self.class.session_repo(session, user_repository_cookie)
        else
          # delete the cookie as the stored repository uri is no longer valid
          cookies.delete(user_repository_cookie_key)
        end
      else
        set_user_repository_cookie(@repositories.first.uri)
        self.class.session_repo(session, @repositories.first.uri)
      end
    end
  end


  def refresh_permissions
    if session[:last_permission_refresh] &&
        session[:last_permission_refresh] < MemoryLeak::Resources.get(:acl_system_mtime)
      User.refresh_permissions(self)
    end
  end


  def refresh_preferences
    if session[:last_preference_refresh] &&
        session[:last_preference_refresh] < MemoryLeak::Resources.get(:preferences_system_mtime)
      session[:preferences] = nil
    end
  end


  def unauthorised_access
    render_403
  end


  def account_self_service
    if !AppConfig[:allow_user_registration] && session[:user].nil?
      unauthorised_access
    end
  end

  def render_403
    return render :status => 403, :template => "403", :layout => nil if inline?

    render "/403"
  end


  def render_404
    return render :template => "404", :layout => nil if inline?

    render "/404"
  end


  # We explicitly set the formats and handlers here to avoid the huge number of
  # stat() syscalls that Rails normally triggers when running in dev mode.
  #
  # It would have been nice to call this 'render_partial', but that name is
  # taken by the default controller.
  #
  def render_aspace_partial(args)
    defaults = {:formats => [:html], :handlers => [:erb]}
    return render(defaults.merge(args))
  end



  def determine_browser_support
    if session[:browser_support]
      @browser_support = session[:browser_support].intern
      return
    end

    user_agent = UserAgent.parse(request.user_agent)

    @browser_support = :unknown
    if BrowserSupport.bronze.detect {|browser| user_agent <= browser}
      @browser_support = :bronze
    elsif BrowserSupport.silver.detect {|browser| user_agent <= browser}
      @browser_support = :silver
    elsif BrowserSupport.silver.detect {|browser| user_agent > browser} || BrowserSupport.gold.detect {|browser| user_agent >= browser}
      @browser_support = :gold
    end

    session[:browser_support] = @browser_support
  end

  protected

  def cleanup_params_for_schema(params_hash, schema)
    fix_arrays = proc do |hash, schema|
      result = hash.clone

      schema['properties'].each do |property, definition|
        if definition['type'] == 'array' && result[property].is_a?(Hash)
          result[property] = result[property].map {|_, v| v}
        end
      end

      result
    end


    set_false_for_checkboxes = proc do |hash, schema|
      result = hash.clone

      schema['properties'].each do |property, definition|
        if definition['type'] == 'boolean'
          if not result.has_key?(property)
            result[property] = false
          else
            result[property] = (result[property].to_i === 1)
          end
        end
      end

      result
    end


    coerce_integers = proc do |hash, schema|

      schema['properties'].each do |property, definition|
        if definition['type'] == 'integer'
          if hash.has_key?(property) && hash[property].is_a?(String)
            if (i = hash[property].to_i) && i > 0
              hash[property] = i
            end
          end
        end
      end

      hash
    end


    expand_multiple_item_linker_values = proc do |hash, schema|
      # The linker widget allows multiple items to be selected for some
      # associations.  In these cases, split up the values and create
      # separate records to be created.

      associations_to_expand = ['linked_agents', 'subjects', 'classifications']

      associations_to_expand.each do |association|
        if hash.has_key?(association)
          all_expanded = []

          hash[association].each do |linked_agent|
            if linked_agent.has_key?('ref') && linked_agent['ref'].is_a?(Array)
              linked_agent['ref'].each_with_index do |ref, i|
                expanded = linked_agent.clone
                expanded['ref'] = ref
                expanded['_resolved'] = linked_agent['_resolved'][i]
                all_expanded.push(expanded)
              end
            else
              all_expanded.push(linked_agent)
            end
          end

          hash[association] = all_expanded
        end
      end

      hash
    end


    deserialise_resolved_json_blobs = proc do |hash, schema|
      # The linker widget sends us the full blob of each record being linked
      # to as a JSON blob.  Make this available as a regular hash by walking
      # the document and deserialising these blobs.

      if hash.has_key?('_resolved') && hash['_resolved'].is_a?(String)
        hash.merge('_resolved' => ASUtils.json_parse(hash['_resolved']))
      else
        hash
      end
    end


    JSONSchemaUtils.map_hash_with_schema(params_hash,
                                         schema,
                                         [fix_arrays,
                                          set_false_for_checkboxes,
                                          deserialise_resolved_json_blobs,
                                          coerce_integers,
                                          expand_multiple_item_linker_values])
  end

  def params_for_backend_search
    params_for_search = params.select{|k,v| ["page", "q", "type", "sort", "exclude", "filter_term", "simple_filter"].include?(k) and not v.blank?}

    params_for_search["page"] ||= 1

    if params_for_search["type"]
      params_for_search["type[]"] = Array(params_for_search["type"]).reject{|v| v.blank?}
      params_for_search.delete("type")
    end

    if params_for_search["filter_term"]
      params_for_search["filter_term[]"] = Array(params_for_search["filter_term"]).reject{|v| v.blank?}
      params_for_search.delete("filter_term")
    end
    
    if params_for_search["simple_filter"]
      params_for_search["simple_filter[]"] = Array(params_for_search["simple_filter"]).reject{|v| v.blank?}
      params_for_search.delete("simple_filter")
    end

    if params_for_search["exclude"]
      params_for_search["exclude[]"] = Array(params_for_search["exclude"]).reject{|v| v.blank?}
      params_for_search.delete("exclude")
    end

    params_for_search
  end

  def parse_tree(node, parent, &block)
    node['children'].map{|child_node| parse_tree(child_node, node, &block)} if node['children']
    block.call(node, parent)
  end


  def prepare_tree_nodes(node, &block)
    node['children'].map{|child_node| prepare_tree_nodes(child_node, &block) }
    block.call(node)
  end


  def handle_transfer(model)
    old_uri = model.uri_for(params[:id])
    response = JSONModel::HTTP.post_form(model.uri_for(params[:id]) + "/transfer",
                                         "target_repo" => params[:ref])

    if response.code == '200'
      flash[:success] = I18n.t("actions.transfer_successful")
    elsif response.code == '409'
    # Transfer failed for a known reason
      raise ArchivesSpace::TransferConflictException.new(ASUtils.json_parse(response.body).fetch('error'))
    else
      flash[:error] = I18n.t("actions.transfer_failed") + ": " + response.body
    end

    redirect_to(:action => :index, :deleted_uri => old_uri)
  end


  helper_method :default_advanced_search_queries
  def default_advanced_search_queries
    [{"i" => 0, "type" => "text"}]
  end


  helper_method :advanced_search_queries
  def advanced_search_queries
    return default_advanced_search_queries if !params["advanced"]

    indexes = params.keys.collect{|k| k[/^v(?<index>[\d]+)/, "index"]}.compact.sort{|a,b| a.to_i <=> b.to_i}

    return default_advanced_search_queries if indexes.empty?

    indexes.map {|i|
      query = {
        "i" => i.to_i,
        "op" => params["op#{i}"],
        "field" => params["f#{i}"],
        "value" => params["v#{i}"],
        "type" => params["t#{i}"]
      }

      if query["op"] === "NOT"
        query["op"] = "AND"
        query["negated"] = true
      end

      if query["type"] == "date"
        query["comparator"] = params["dop#{i}"]
      end

      if query["type"] == "boolean"
        query["value"] = query["value"] == "true"
      end

      query
    }
  end

end
