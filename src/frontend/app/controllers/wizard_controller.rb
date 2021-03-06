class WizardController < ApplicationController

  # GET/POST /source/<project>/<package>/_wizard
  def package_wizard
    prj_name = params[:project]
    pkg_name = params[:package]
    pkg = DbPackage.find_by_project_and_name(prj_name, pkg_name)
    unless pkg
      render_error :status => 404, :errorcode => "unknown_package",
        :message => "unknown package '#{pkg_name}' in project '#{prj_name}'"
      return
    end
    if not @http_user.can_modify_package?(pkg)
      render_error :status => 403, :errorcode => "change_package_no_permission",
        :message => "no permission to change package"
      return
    end

    logger.debug("package_wizard, #{params.inspect}")

    wizard_xml = "/source/#{prj_name}/#{pkg_name}/wizard.xml"
    begin
      @wizard_state = WizardState.new(backend_get(wizard_xml))
    rescue ActiveXML::Transport::NotFoundError
      @wizard_state = WizardState.new("")
    end
    @wizard_state.data["name"] = pkg_name
    wizard_step_tarball
    if @wizard_state.dirty
      backend_put(wizard_xml, @wizard_state.serialize)
    end
  end

  private

  @@wizard_entries = {
    # name => [type, description, legend]
    "tarball"     => ["file", "Source tarball to upload", ""],
    "version"     => ["text", "Version of the package", "Note that the version must not contain dashes (-)"],
    "summary"     => ["text", "Short summary of the package", ""],
    "description" => ["longtext", "Describe your package", ""],
    "license"     => ["text", "License of the package", ""],
    "group"       => ["text", "Package group", "See http://en.opensuse.org/SUSE_Package_Conventions/RPM_Groups"],
    # autogenerated
    "name"        => [],
  }

  def wizard_add_entry(name)
    @wizard_form.add_entry(name,
                           @@wizard_entries[name][0],
                           @@wizard_entries[name][1],
                           @@wizard_entries[name][2],
                           @wizard_state[name])
  end

  def wizard_step_tarball
    if params[:tarball] && ! params[:tarball].empty?
      filename = params[:tarball]
      # heuristics
      @wizard_state.data["tarball"] = filename
      if filename =~ /^#{params[:package]}-(.*)\.tar\.(gz|bz2)$/i
        @wizard_state.guess["version"] = $1
      end
      @wizard_state.guess["group"] = "Productivity/Other"
      @wizard_state.guess["license"] = "GPL v2 or later"
      # TODO: unpack the tarball somehow and try to guess as much as possible...
    end
    if @wizard_state.data["tarball"]
      wizard_step_meta
      return
    end
    @wizard_form = WizardForm.new("Step 1/2", "What do you want to package?")
    @wizard_form.add_entry("tarball", "file", "Source tarball to upload")
    render :template => "wizard", :status => 200;
  end

  def wizard_step_meta
    have_all = true
    ["version", "summary", "description", "license", "group"].each do |entry|
      if params[entry] && ! params[entry].empty?
        @wizard_state.data[entry] = params[entry]
      end
      if ! @wizard_state.data[entry]
        have_all = false
      end
    end
    if have_all
      wizard_step_finish
      return
    end
    @wizard_form = WizardForm.new("Step 2/2", "Please describe your package")
    wizard_add_entry("summary")
    wizard_add_entry("description")
    wizard_add_entry("version")
    wizard_add_entry("license")
    wizard_add_entry("group")
    render :template => "wizard", :status => 200
  end

  def wizard_step_finish
    if @wizard_state.data["created_spec"] == "true"
      wizard_step_done
      return
    end
    package = Package.find(params[:package], :project => params[:project])
    # FIXME: is there a cleaner way to do it?
    package.data.elements["title"].text = @wizard_state.data["summary"]
    package.data.elements["description"].text = @wizard_state.data["description"]
    package.save
    specfile = "#{params[:package]}.spec"
    template = File.read("#{RAILS_ROOT}/files/wizardtemplate.spec")
    erb = ERB.new(template)
    template = erb.result(binding)
    backend_put("/source/#{params[:project]}/#{params[:package]}/#{specfile}", template)
    @wizard_state.data["created_spec"] = "true"
    @wizard_form = WizardForm.new("Finished",
      "I created #{specfile} for you. Please review it and adjust it to fit your needs.")
    @wizard_form.last = true
    render :template => "wizard", :status => 200
  end

  def wizard_step_done
    @wizard_form = WizardForm.new("Nothing to do",
    "There is nothing I can do for you now. In the future, I will be able to help you updating your package or fixing build errors")
    @wizard_form.last = true
    render :template => "wizard", :status => 200
  end

end

# vim:et:ts=2:sw=2
