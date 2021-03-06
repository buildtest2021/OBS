require "rexml/document"

class SourceController < ApplicationController
  validate_action :index => :directory, :packagelist => :directory, :filelist => :directory
  validate_action :project_meta => :project, :package_meta => :package, :pattern_meta => :pattern
 
  skip_before_filter :extract_user, :only => [:file, :project_meta, :project_config] 

  def index
    projectlist
  end

  def projectlist
    @dir = Project.find :all
    render :text => @dir.dump_xml, :content_type => "text/xml"
  end

  def index_project
    project_name = params[:project]
    pro = DbProject.find_by_name project_name
    if pro.nil?
      render_error :status => 404, :errorcode => 'unknown_project',
        :message => "Unknown project #{project_name}"
      return
    end
    
    if request.get?
      @dir = Package.find :all, :project => project_name
      render :text => @dir.dump_xml, :content_type => "text/xml"
      return
    elsif request.delete?
      unless @http_user.can_modify_project?(pro)
        logger.debug "No permission to delete project #{project_name}"
        render_error :status => 403, :errorcode => 'delete_project_no_permission',
          :message => "Permission denied (delete project #{project_name})"
        return
      end

      #deny deleting if other packages use this as develproject
      unless pro.develpackages.empty?
        msg = "Unable to delete project #{pro.name}; following packages use this project as develproject: "
        msg += pro.develpackages.map {|pkg| pkg.db_project.name+"/"+pkg.name}.join(", ")
        render_error :status => 400, :errorcode => 'develproject_dependency',
          :message => msg
        return
      end

      #find linking repos
      lreps = Array.new
      pro.repositories.each do |repo|
        repo.linking_repositories.each do |lrep|
          lreps << lrep
        end
      end

      if lreps.length > 0
        if params[:force] and not params[:force].empty?
          #replace links to this projects with links to the "deleted" project
          del_repo = DbProject.find_by_name("deleted").repositories[0]
          lreps.each do |link_rep|
            pe = link_rep.path_elements.find(:first, :include => ["link"], :conditions => ["db_project_id = ?", pro.id])
            pe.link = del_repo
            pe.save
            #update backend
            link_prj = link_rep.db_project
            logger.info "updating project '#{link_prj.name}'"
            Suse::Backend.put_source "/source/#{link_prj.name}/_meta", link_prj.to_axml
          end
        else
          lrepstr = lreps.map{|l| l.db_project.name+'/'+l.name}.join "\n"
          render_error :status => 400, :errorcode => "repo_dependency",
            :message => "Unable to delete project #{project_name}; following repositories depend on this project:\n#{lrepstr}\n"
          return
        end
      end

      #destroy all packages
      pro.db_packages.each do |pack|
        DbPackage.transaction do
          logger.info "destroying package #{pack.name}"
          pack.destroy
          logger.debug "delete request to backend: /source/#{pro.name}/#{pack.name}"
          Suse::Backend.delete "/source/#{pro.name}/#{pack.name}"
        end
      end

      DbProject.transaction do
        logger.info "destroying project #{pro.name}"
        pro.destroy
        logger.debug "delete request to backend: /source/#{pro.name}"
        Suse::Backend.delete "/source/#{pro.name}"
      end

      render_ok
      return
    elsif request.post?
      cmd = params[:cmd]
      if @http_user.can_modify_project?(pro)
        dispatch_command
      else
        render_error :status => 403, :errorcode => "cmd_execution_no_permission",
          :message => "no permission to execute command '#{cmd}'"
        return
      end
    else
      render_error :status => 400, :errorcode => "illegal_request",
        :message => "illegal POST request to #{request.request_uri}"
    end
  end

  def index_package
    project_name = params[:project]
    package_name = params[:package]
    cmd = params[:cmd]

    pkg = DbPackage.find_by_project_and_name(project_name, package_name)
    unless pkg
      render_error :status => 404, :errorcode => "unknown_package",
        :message => "unknown package '#{package_name}' in project '#{project_name}'"
      return
    end

    if request.get?
      pass_to_source
      return
    elsif request.delete?
      if not @http_user.can_modify_package?(pkg)
        render_error :status => 403, :errorcode => "delete_package_no_permission",
          :message => "no permission to delete package #{package_name}"
        return
      end
      
      DbPackage.transaction do
        pkg.destroy
        Suse::Backend.delete "/source/#{project_name}/#{package_name}"
      end
      render_ok
    elsif request.post?
      if not @http_user.can_modify_package?(pkg) and not ['diff', 'branch'].include?(cmd)
        render_error :status => 403, :errorcode => "cmd_execution_no_permission",
          :message => "no permission to execute command '#{cmd}'"
        return
      end
      
      dispatch_command
    end
  end

  def pattern_meta
    valid_http_methods :get, :put, :delete

    comment = params[:comment]
    rev = params[:rev]
    if @http_user
      user = @http_user.login
    else
      user = params[:user]
    end
    
    @project = DbProject.find_by_name params[:project]
    unless @project
      render_error :message => "Unknown project '#{params[:project]}'",
        :status => 404, :errorcode => "unknown_project"
      return
    end

    if request.get?
      pass_to_source
    else
      # PUT and DELETE
      permerrormsg = nil
      if request.put?
        permerrormsg = "no permission to store pattern"
      elsif request.delete?
        permerrormsg = "no permission to delete pattern"
      end

      unless @http_user.can_modify_project? @project
        logger.debug "user #{user.login} has no permission to modify project #{@project}"
        render_error :status => 403, :errorcode => "change_project_no_permission", 
          :message => permerrormsg
        return
      end
      
      query_string = [['rev',rev],['user',user],['comment',comment]].reject{|x| x[1].nil?}.map{|x| x.join('=')}.join('&')
      path = "#{request.path}?#{query_string}"
      
      forward_data path, :method => request.method
    end
  end

  # GET /source/:project/_pattern
  def index_pattern
    valid_http_methods :get

    unless DbProject.find_by_name(params[:project])
      render_error :message => "Unknown project '#{params[:project]}'",
        :status => 404, :errorcode => "unknown_project"
      return
    end
    
    pass_to_source
  end

  def project_meta
    project_name = params[:project]
    if project_name.nil?
      render_error :status => 400, :errorcode => 'missing_parameter',
        :message => "parameter 'project' is missing"
      return
    end

    unless valid_project_name? project_name
      render_error :status => 400, :errorcode => "invalid_project_name",
        :message => "invalid project name '#{project_name}'"
      return
    end

    if request.get?
      @project = DbProject.find_by_name( project_name )
      unless @project
        render_error :message => "Unknown project '#{project_name}'",
          :status => 404, :errorcode => "unknown_project"
        return
      end
      render :text => @project.to_axml, :content_type => 'text/xml'
      return
    end

    #authenticate
    return unless extract_user

    if request.put?
      # Need permission
      logger.debug "Checking permission for the put"
      allowed = false
      request_data = request.raw_post

      @project = DbProject.find_by_name( project_name )
      if @project
        #project exists, change it
        unless @http_user.can_modify_project? @project
          logger.debug "user #{user.login} has no permission to modify project #{@project}"
          render_error :status => 403, :errorcode => "change_project_no_permission", 
            :message => "no permission to change project"
          return
        end
      else
        #project is new
        unless @http_user.can_create_project? project_name
          logger.debug "Not allowed to create new project"
          render_error :status => 403, :errorcode => 'create_project_no_permission',
            :message => "not allowed to create new project '#{project_name}'"
          return
        end
      end
      
      p = Project.new(request_data, :name => project_name)

      if p.name != project_name
        render_error :status => 400, :errorcode => 'project_name_mismatch',
          :message => "project name in xml data does not match resource path component"
        return
      end

      if (p.has_element? :remoteurl or p.has_element? :remoteproject) and not @http_user.is_admin?
        render_error :status => 403, :errorcode => "change_project_no_permission",
          :message => "admin rights are required to change remoteurl or remoteproject"
        return
      end

      p.add_person(:userid => @http_user.login) unless @project
      p.save

      render_ok
    else
      render_error :status => 400, :errorcode => 'illegal_request',
        :message => "Illegal request: POST #{request.path}"
    end
  end

  def project_config
    valid_http_methods :get, :put

    #check if project exists
    unless (@project = DbProject.find_by_name(params[:project]))
      render_error :status => 404, :errorcode => 'project_not_found',
        :message => "Unknown project #{params[:project]}"
      return
    end

    #assemble path for backend
    path = request.path
    unless request.query_string.empty?
      path += "?" + request.query_string
    end

    if request.get?
      forward_data path
      return
    end

    #authenticate
    return unless extract_user

    if request.put?
      unless @http_user.can_modify_project?(@project)
        render_error :status => 403, :errorcode => 'put_project_config_no_permission',
          :message => "No permission to write build configuration for project '#{params[:project]}'"
        return
      end

      forward_data path, :method => :put
      return
    end
  end

  def project_pubkey
    valid_http_methods :get, :delete

    #check if project exists
    unless (@project = DbProject.find_by_name(params[:project]))
      render_error :status => 404, :errorcode => 'project_not_found',
        :message => "Unknown project #{params[:project]}"
      return
    end

    #assemble path for backend
    path = request.path
    unless request.query_string.empty?
      path += "?" + request.query_string
    end

    if request.get?
      forward_data path
    elsif request.delete?
      #check for permissions
      unless @http_user.can_modify_project?(@project)
        render_error :status => 403, :errorcode => 'delete_project_pubkey_no_permission',
          :message => "No permission to delete public key for project '#{params[:project]}'"
        return
      end

      forward_data path, :method => :delete
      return
    end
  end

  def package_meta
    #TODO: needs cleanup/split to smaller methods
    valid_http_methods :put, :get
   
    project_name = params[:project]
    package_name = params[:package]

    if project_name.nil?
      render_error :status => 400, :errorcode => "parameter_missing",
        :message => "parameter 'project' missing"
      return
    end

    if package_name.nil?
      render_error :status => 400, :errorcode => "parameter_missing",
        :message => "parameter 'package' missing"
      return
    end

    unless pro = DbProject.find_by_name(project_name)
      render_error :status => 404, :errorcode => "unknown_project",
        :message => "Unknown project '#{project_name}'"
      return
    end

    if request.get?
      unless pack = pro.db_packages.find_by_name(package_name)
        render_error :status => 404, :errorcode => "unknown_package",
          :message => "Unknown package '#{package_name}'"
        return
      end

      render :text => pack.to_axml, :content_type => 'text/xml'
    elsif request.put?
      allowed = false
      request_data = request.raw_post
      begin
        # Try to fetch the package to see if it already exists
        @package = Package.find( package_name, :project => project_name )
  
        # Being here means that the project already exists
        allowed = permissions.package_change? @package
        if allowed
          @package = Package.new( request_data, :project => project_name, :name => package_name )
        else
          logger.debug "user #{user.login} has no permission to change package #{@package}"
          render_error :status => 403, :errorcode => "change_package_no_permission",
            :message => "no permission to change package"
          return
        end
      rescue ActiveXML::Transport::NotFoundError
        # Ok, the project is new
        allowed = permissions.package_create?( project_name )
  
        if allowed
          #FIXME: parameters that get substituted into the url must be specified here... should happen
          #somehow automagically... no idea how this might work
          @package = Package.new( request_data, :project => project_name, :name => package_name )
        
          # add package creator as maintainer if he is not added already
          if not @package.has_element?( "person[@userid='#{user.login}']" )
            @package.add_person( :userid => user.login )
          end
        else
          # User is not allowed by global permission.
          logger.debug "Not allowed to create new packages"
          render_error :status => 403, :errorcode => "create_package_no_permission",
            :message => "no permission to create package for project #{project_name}"
          return
        end
      end
      
      if allowed
        if( @package.name != package_name )
          render_error :status => 400, :errorcode => 'package_name_mismatch',
            :message => "package name in xml data does not match resource path component"
          return
        end

        @package.save
        render_ok
      else
        logger.debug "user #{user.login} has no permission to write package meta for package #@package"
      end
    end
  end

  def file
    project_name = params[:project]
    package_name = params[:package]
    file = params[:file]
    params[:user] = @http_user.login if @http_user

    path = "/source/#{project_name}/#{package_name}/#{file}"

    if request.get?
      #get file size
      fpath = "/source/#{project_name}/#{package_name}" + build_query_from_hash(params, [:rev])
      file_list = Suse::Backend.get(fpath)
      regexp = file_list.body.match(/name=["']#{Regexp.quote file}["'].*size=["']([^"']*)["']/)
      if regexp
        fsize = regexp[1]
        
        path += build_query_from_hash(params, [:rev])
        logger.info "streaming #{path}"
       
        headers.update(
          'Content-Disposition' => %(attachment; filename="#{file}"),
          'Content-Type' => 'application/octet-stream',
          'Transfer-Encoding' => 'binary',
          'Content-Length' => fsize
        )
        
        render :status => 200, :text => Proc.new {|request,output|
          backend_request = Net::HTTP::Get.new(path)
          response = Net::HTTP.start(SOURCE_HOST,SOURCE_PORT) do |http|
            http.request(backend_request) do |response|
              response.read_body do |chunk|
                output.write(chunk)
              end
            end
          end
        }
      else
        forward_data path
      end
      return
    end

    #authenticate
    return unless extract_user

    if request.put?
      path += build_query_from_hash(params, [:user, :comment, :rev, :keeplink])
      
      allowed = permissions.package_change? package_name, project_name
      if  allowed
        Suse::Backend.put_source path, request.raw_post
        package = Package.find( package_name, :project => project_name )
        package.update_timestamp
        logger.info "wrote #{request.raw_post.to_s.size} bytes to #{path}"
        render_ok
      else
        render_error :status => 403, :errorcode => 'put_file_no_permission',
          :message => "Insufficient permissions to store file in package #{package_name}, project #{project_name}"
      end
    elsif request.delete?
      path += build_query_from_hash(params, [:user, :comment, :rev, :keeplink])
      
      allowed = permissions.package_change? package_name, project_name
      if  allowed
        Suse::Backend.delete path
        package = Package.find( package_name, :project => project_name )
        package.update_timestamp
        render_ok
      else
        render_error :status => 403, :errorcode => 'delete_file_no_permission',
          :message => "Insufficient permissions to delete file"
      end
    end
  end

  private

  # POST /source/<project>?cmd=createkey
  def index_project_createkey
    path = request.path + "?" + request.query_string
    forward_data path, :method => :post
  end

  # POST /source/<project>/<package>?cmd=createSpecFileTemplate
  def index_package_createSpecFileTemplate
    specfile_path = "#{request.path}/#{params[:package]}.spec"
    begin
      backend_get( specfile_path )
      render_error :status => 400, :errorcode => "spec_file_exists",
        :message => "SPEC file already exists."
      return
    rescue ActiveXML::Transport::NotFoundError
      specfile = File.read "#{RAILS_ROOT}/files/specfiletemplate"
      backend_put( specfile_path, specfile )
    end
    render_ok
  end

  # POST /source/<project>/<package>?cmd=rebuild
  def index_package_rebuild
    project_name = params[:project]
    package_name = params[:package]
    repo_name = params[:repo]
    arch_name = params[:arch]

    path = "/build/#{project_name}?cmd=rebuild&package=#{package_name}"
    
    p = DbProject.find_by_name project_name
    if p.nil?
      render_error :status => 400, :errorcode => 'unknown_project',
        :message => "Unknown project '#{project_name}'"
      return
    end

    if p.db_packages.find_by_name(package_name).nil?
      render_error :status => 400, :errorcode => 'unknown_package',
        :message => "Unknown package '#{package_name}'"
      return
    end

    if repo_name
      path += "&repository=#{repo_name}"
      if p.repositories.find_by_name(repo_name).nil?
        render_error :status => 400, :errorcode => 'unknown_repository',
          :message=> "Unknown repository '#{repo_name}'"
        return
      end
    end

    if arch_name
      path += "&arch=#{arch_name}"
    end

    backend.direct_http( URI(path), :method => "POST", :data => "" )
    render_ok
  end

  # POST /source/<project>/<package>?cmd=commit
  def index_package_commit
    params[:user] = @http_user.login if @http_user

    path = request.path
    path << build_query_from_hash(params, [:cmd, :user, :comment, :rev, :keeplink])
    forward_data path, :method => :post
  end

  # POST /source/<project>/<package>?cmd=diff
  def index_package_diff
    path = request.path + "?" + request.query_string
    forward_data path, :method => :post
  end

  # POST /source/<project>/<package>?cmd=copy
  def index_package_copy
    params[:user] = @http_user.login if @http_user

    pack = DbPackage.find_by_project_and_name(params[:project], params[:package])
    if pack.nil? 
      render_error :status => 404, :errorcode => 'unknown_package',
        :message => "Unknown package #{params[:package]} in project #{params[:project]}"
      return
    end

    #permission check
    if not @http_user.can_modify_package?(pack)
      render_error :status => 403, :errorcode => "cmd_execution_no_permission",
        :message => "no permission to execute command 'copy'"
      return
    end

    path = request.path
    path << build_query_from_hash(params, [:cmd, :rev, :user, :comment, :oproject, :opackage, :orev, :expand])
    
    forward_data path, :method => :post
  end

  # POST /source/<project>/<package>?cmd=branch
  def index_package_branch
    params[:user] = @http_user.login
    prj_name = params[:project]
    pkg_name = params[:package]

    prj = DbProject.find_by_name prj_name
    pkg = prj.db_packages.find_by_name(pkg_name)
    if pkg.nil?
      render_error :status => 404, :errorcode => 'unknown_package',
        :message => "Unknown package #{pkg_name} in project #{prj_name}"
      return
    end

    # reroute if devel project is set
    if pkg.develproject and not params[:ignoredevel]
      prj = pkg.develproject
      prj_name = prj.name
      pkg = prj.db_packages.find_by_name(pkg_name)

      if pkg.nil?
        render_error :status => 404, :errorcode => 'unknown_package',
          :message => "Unknown package #{pkg_name} in project #{prj_name}"
        return
      end
    end
 
    oprj_name = "home:#{@http_user.login}:branches:#{prj_name}"
    opkg_name = pkg_name

    unless @http_user.can_create_project?(oprj_name)
      render_error :status => 403, :errorcode => "create_project_no_permission",
        :message => "no permission to create project '#{oprj_name}' while executing branch command"
      return
    end

    #create branch container
    oprj = DbProject.find_by_name oprj_name
    if oprj.nil?
      DbProject.transaction do
        oprj = DbProject.new :name => oprj_name, :title => prj.title, :description => prj.description
        oprj.add_user @http_user, "maintainer"
        prj.repositories.each do |repo|
          orepo = Repository.new :name => repo.name
          orepo.architectures = repo.architectures
          orepo.path_elements << PathElement.new(:link => repo)
          oprj.repositories << orepo
        end
        oprj.save
      end
      Project.find(oprj_name).save
    end

    #create branch package
    if opkg = oprj.db_packages.find_by_name(opkg_name)
      render_error :status => 400, :errorcode => "double_branch_package",
        :message => "branch target package already exists: #{oprj_name}/#{opkg_name}"
      return
    else
      opkg = DbPackage.new(:name => opkg_name, :title => pkg.title, :description => pkg.description)
      oprj.db_packages << opkg
    
      opkg.add_user @http_user, "maintainer"
      Package.find(opkg_name, :project => oprj_name).save
    end

    #link sources
    link_data = "<link project='#{prj_name}' package='#{pkg_name}'/>"
    logger.debug "link_data: #{link_data}"
    Suse::Backend.put "/source/#{oprj_name}/#{opkg_name}/_link", link_data

    render_ok :data => {:targetproject => oprj_name}
  end

  def valid_project_name? name
    name =~ /^\w[-_+\w\.:]+$/
  end

  def valid_package_name? name
    name =~ /^\w[-_+\w\.]+$/
  end

end
