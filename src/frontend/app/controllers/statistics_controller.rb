
require 'rexml/document'
require "rexml/streamlistener"

class StatisticsController < ApplicationController


  before_filter :get_limit, :only => [
    :highest_rated, :most_active, :latest_added, :latest_updated,
    :latest_built, :download_counter
  ]

  caches_action :highest_rated, :most_active, :latest_added, :latest_updated,
    :latest_built, :download_counter

  validate_action :redirect_stats => :redirect_stats


  # StreamHandler for parsing incoming download_stats / redirect_stats (xml)
  class StreamHandler
    include REXML::StreamListener

    attr_accessor :errors

    def initialize
      @errors = []
      # build hashes for caching id-/name- combinations
      projects = DbProject.find :all, :select => 'id, name'
      packages = DbPackage.find :all, :select => 'id, name, db_project_id'
      repos  =  Repository.find :all, :select => 'id, name, db_project_id'
      archs = Architecture.find :all, :select => 'id, name'
      @project_hash = @package_hash = @repo_hash = @arch_hash = {}
      projects.each { |p| @project_hash[ p.name ] = p.id }
      packages.each { |p| @package_hash[ [ p.name, p.db_project_id ] ] = p.id }
      repos.each { |r| @repo_hash[ [ r.name, r.db_project_id ] ] = r.id }
      archs.each { |a| @arch_hash[ a.name ] = a.id }
    end

    def tag_start name, attrs
      case name
      when 'project'
        @@project_name = attrs['name']
        @@project_id = @project_hash[ attrs['name'] ]
      when 'package'
        @@package_name = attrs['name']
        @@package_id = @package_hash[ [ attrs['name'], @@project_id ] ]
      when 'repository'
        @@repo_name = attrs['name']
        @@repo_id = @repo_hash[ [ attrs['name'], @@project_id ] ]
      when 'arch'
        @@arch_name = attrs['name']
        unless @@arch_id = @arch_hash[ attrs['name'] ]
          # create new architecture entry (db and hash)
          arch = Architecture.new( :name => attrs['name'] )
          arch.save
          @arch_hash[ arch.name ] = arch.id
          @@arch_id = @arch_hash[ arch.name ]
        end
      when 'count'
        @@count = {
          :filename => attrs['filename'],
          :filetype => attrs['filetype'],
          :version => attrs['version'],
          :release => attrs['release'],
          :created_at => attrs['created_at'],
          :counted_at => attrs['counted_at']
        }
      end
    end

    def text( text )
      text.strip!
      return if text == ''
      unless @@project_id and @@package_id and @@repo_id and @@arch_id and @@count
        @errors << {
          :project_id => @@project_id, :project_name => @@project_name,
          :package_id => @@package_id, :package_name => @@package_name,
          :repo_id => @@repo_id, :repo_name => @@repo_name,
          :arch_id => @@arch_id, :arch_name => @@arch_name, :count => @@count
        }
        return
      end

      # lower the log level, prevent spamming the logfile
      old_loglevel = DownloadStat.logger.level
      DownloadStat.logger.level = Logger::ERROR

      # try to find existing entry in database
      ds = DownloadStat.find :first, :conditions => [
        'db_project_id=? AND db_package_id=? AND repository_id=? AND ' +
        'architecture_id=? AND filename=? AND filetype=? AND ' +
        'version=? AND download_stats.release=?',
        @@project_id, @@package_id, @@repo_id, @@arch_id,
        @@count[:filename], @@count[:filetype],
        @@count[:version], @@count[:release]
      ]
      if ds
        # entry found, update it if necessary ...
        if ds.count.to_i != text.to_i
          ds.count = text
          ds.counted_at = @@count[:counted_at]
          ds.save
        end
      else
        # create new entry - we do this directly per sql statement, because
        # that's much faster than through ActiveRecord objects
        DownloadStat.connection.insert "\
        INSERT INTO download_stats ( \
          `db_project_id`, `db_package_id`, `repository_id`, `architecture_id`,\
          `filename`, `filetype`, `version`, `release`,\
          `counted_at`, `created_at`, `count`\
        ) VALUES(\
          '#{@@project_id}', '#{@@package_id}', '#{@@repo_id}', '#{@@arch_id}',\
          '#{@@count[:filename]}',   '#{@@count[:filetype]}',\
          '#{@@count[:version]}',    '#{@@count[:release]}',\
          '#{@@count[:counted_at]}', '#{@@count[:created_at]}',\
          '#{text}'\
        )", "Creating DownloadStat entry: "
      end

      # reset the log level
      DownloadStat.logger.level = old_loglevel
    end
  end




  def index
    text =  "This is the statistics controller.<br />"
    text += "See the api documentation for details."
    render :text => text
  end


  def highest_rated
    # set automatic action_cache expiry time limit
    response.time_to_live = 10.minutes

    ratings = Rating.find :all,
      :select => 'object_id, object_type, count(score) as count,' +
        'sum(score)/count(score) as score_calculated',
      :group => 'object_id, object_type',
      :order => 'score_calculated DESC'
    ratings = ratings.delete_if { |r| r.count.to_i < min_votes_for_rating }
    @ratings = ratings[0..@limit-1]
  end


  def rating
    @package = params[:package]
    @project = params[:project]

    begin
      object = DbProject.find_by_name @project
      object = DbPackage.find :first, :conditions =>
        [ 'name=? AND db_project_id=?', @package, object.id ] if @package
      throw if object.nil?
    rescue
      @package = @project = @rating = object = nil
      return
    end

    if request.get?

      @rating = object.rating( @http_user.id )

    elsif request.put?

      # try to get previous rating of this user for this object
      previous_rating = Rating.find :first, :conditions => [
        'object_type=? AND object_id=? AND user_id=?',
        object.class.name, object.id, @http_user.id
      ]
      data = ActiveXML::Base.new( request.raw_post )
      if previous_rating
        # update previous rating
        previous_rating.score = data.to_s.to_i
        previous_rating.save
      else
        # create new rating entry
        begin
          rating = Rating.new
          rating.score = data.to_s.to_i
          rating.object_type = object.class.name
          rating.object_id = object.id
          rating.user_id = @http_user.id
          rating.save
        rescue
          render_error :status => 400, :errorcode => "error setting rating",
            :message => "rating not saved"
          return
        end
      end
      render_ok

    else
      render_error :status => 400, :errorcode => "invalid_method",
        :message => "only GET or PUT method allowed for this action"
    end
  end


  def download_counter
    # set automatic action_cache expiry time limit
    response.time_to_live = 30.minutes

    # initialize @stats
    @stats = []

    # get total count of all downloads
    @all = DownloadStat.find( :first, :select => 'sum(count) as sum' ).sum
    @all = 0 unless @all

    # get timestamp of first counted entry
    time = DownloadStat.find( :first, :select => 'min(created_at) as ts' ).ts
    time ? @first = Time.parse( time ).xmlschema : @first = Time.now.xmlschema

    # get timestamp of last counted entry
    time = DownloadStat.find( :first, :select => 'max(counted_at) as ts' ).ts
    time ? @last = Time.parse( time ).xmlschema : @last = Time.now.xmlschema

    if @group_by_mode = params[:group_by]
    # if in group_by_mode, then we concatenate download_stats entries

      # generate parts of the sql statement
      case @group_by_mode
      when 'project'
        from = 'db_projects pro'
        select = 'pro.name as obj_name'
        group_by = 'db_project_id'
        conditions = 'ds.db_project_id=pro.id'
      when 'package'
        from = 'db_packages pac, db_projects pro'
        select = 'pac.name as obj_name, pro.name as pro_name'
        group_by = 'db_package_id'
        conditions = 'ds.db_package_id=pac.id AND ds.db_project_id=pro.id'
      when 'repo'
        from = 'repositories repo, db_projects pro'
        select = 'repo.name as obj_name, pro.name as pro_name'
        group_by = 'repository_id'
        conditions = 'ds.repository_id=repo.id AND ds.db_project_id=pro.id'
      when 'arch'
        from = 'architectures arch'
        select = 'arch.name as obj_name'
        group_by = 'architecture_id'
        conditions = 'ds.architecture_id=arch.id'
      else
        @cstats = nil
        return
      end

      # execute the sql query
      @stats = DownloadStat.find :all,
        :from => 'download_stats ds, ' + from,
        :select => 'ds.*, ' + select + ', ' +
          'sum(ds.count) as counter_sum, count(ds.id) as files_count',
        :conditions => conditions,
        :order => 'counter_sum DESC, files_count ASC',
        :group => group_by,
        :limit => @limit

    else
    # we are not in group_by_mode, so we return full download_stats data

      # get objects
      prj = DbProject.find_by_name params[:project]
      pac = DbPackage.find :first, :conditions => [
        'name=? AND db_project_id=?', params[:package], prj.id
      ] if prj
      repo = Repository.find :first, :conditions => [
        'name=? AND db_project_id=?', params[:repo], prj.id
      ] if prj
      arch = Architecture.find_by_name params[:arch]

      # return immediately, if any object is invalid / not found
      return if not prj  and not params[:project].nil?
      return if not pac  and not params[:package].nil?
      return if not repo and not params[:repo].nil?
      return if not arch and not params[:arch].nil?

      # create filter, if parameters given & objects found
      filter = ''
      filter += " AND ds.db_project_id=#{prj.id}" if prj
      filter += " AND ds.db_package_id=#{pac.id}" if pac
      filter += " AND ds.repository_id=#{repo.id}" if repo
      filter += " AND ds.architecture_id=#{arch.id}" if arch
      
      # get download_stats entries
      @stats = DownloadStat.find :all,
        :from => 'download_stats ds, db_projects pro, db_packages pac, ' +
          'architectures arch, repositories repo',
        :select => 'ds.*, pro.name as pro_name, pac.name as pac_name, ' +
          'arch.name as arch_name, repo.name as repo_name',
        :conditions => 'ds.db_project_id=pro.id AND ds.db_package_id=pac.id' +
          ' AND ds.architecture_id=arch.id AND ds.repository_id=repo.id' +
          filter,
        :order => 'ds.count DESC',
        :limit => @limit

      # get sum of counts
      @sum = DownloadStat.find( :first,
        :from => 'download_stats ds',
        :select => 'sum(count) as overall_counter',
        :conditions => '1=1' + filter
      ).overall_counter
    end
  end


  def redirect_stats

    #breakpoint "redirect problem"
    # check permissions
    unless permissions.set_download_counters
      render_error :status => 403, :errorcode => "permission denied",
        :message => "download counters cannot be set, insufficient permissions"
      return
    end

    # get download statistics from redirector as xml
    if request.put?
      data = request.raw_post

      # parse the data
      streamhandler = StreamHandler.new
      logger.debug "download_stats import starts now ..."
      REXML::Document.parse_stream( data, streamhandler )
      logger.debug "download_stats import is finished."

      if streamhandler.errors
        logger.debug "prepare download_stats warning message..."
        err_count = streamhandler.errors.length
        dayofweek = Time.now.strftime('%u')
        logfile = "log/download_statistics_import_warnings-#{dayofweek}.log"
        msg  = "WARNING: #{err_count} redirect_stats were not imported.\n"
        msg += "(for details see logfile #{logfile})"

        f = File.open logfile, 'w'
        streamhandler.errors.each do |e|
          f << "project: #{e[:project_name]}=#{e[:project_id] or '*UNKNOWN*'}  "
          f << "package: #{e[:package_name]}=#{e[:package_id] or '*UNKNOWN*'}  "
          f << "repo: #{e[:repo_name]}=#{e[:repo_id] or '*UNKNOWN*'}  "
          f << "arch: #{e[:arch_name]}=#{e[:arch_id] or '*UNKNOWN*'}\t"
          f << "(#{e[:count][:filename]}:#{e[:count][:version]}:"
          f << "#{e[:count][:release]}:#{e[:count][:filetype]})\n"
        end
        f.close

        logger.warn "\n\n#{msg}\n\n"
        render_ok msg # render_ok with msg text in details
      else
        render_ok
      end

    else
      render_error :status => 400, :errorcode => "only_put_method_allowed",
        :message => "only PUT method allowed for this action"
      logger.debug "Tried to access download_stats via '#{request.method}' - not allowed!"
      return
    end
  end

  def newest_stats
    # check permissions
    # no permission needed

    ds = DownloadStat.find :first, :order => "counted_at DESC", :limit => 1
    @newest_stats = ds.nil? ? Time.at(0).xmlschema : ds.counted_at.xmlschema
  end
 


  def most_active
    # set automatic action_cache expiry time limit
    response.time_to_live = 30.minutes

    @type = params[:type] or @type = 'packages'

    if @type == 'projects'
      # get all packages including activity values
      @packages = DbPackage.find :all,
        :from => 'db_packages pac, db_projects pro',
        :conditions => 'pac.db_project_id = pro.id',
        :select => 'pac.*, pro.name AS project_name,' +
          "( #{DbPackage.activity_algorithm} ) AS act_tmp," +
          'IF( @activity<0, 0, @activity ) AS activity_value'
      # count packages per project and sum up activity values
      projects = {}
      @packages.each do |package|
        pro = package.project_name
        projects[pro] ||= { :count => 0, :sum => 0 }
        projects[pro][:count] += 1
        projects[pro][:sum] += package.activity_value.to_f
      end
      # calculate average activity of packages per project
      projects.each_key do |pro|
        projects[pro][:activity] = projects[pro][:sum] / projects[pro][:count]
      end
      # sort by activity
      @projects = projects.sort do |a,b|
        b[1][:activity] <=> a[1][:activity]
      end
      # apply limit
      @projects = @projects[0..@limit-1]

    elsif @type == 'packages'
      # get all packages including activity values
      @packages = DbPackage.find :all,
        :from => 'db_packages pac, db_projects pro',
        :conditions => 'pac.db_project_id = pro.id',
        :order => 'activity_value DESC',
        :limit => @limit,
        :select => 'pac.*, pro.name AS project_name,' +
          "( #{DbPackage.activity_algorithm} ) AS act_tmp," +
          'IF( @activity<0, 0, @activity ) AS activity_value'
    end
  end


  def activity
    @project = DbProject.find_by_name params[:project]
    @package = DbPackage.find :first, :conditions => [
      'name=? AND db_project_id=?', params[:package], @project.id ] if @project
  end


  def latest_added
    # set automatic action_cache expiry time limit
    response.time_to_live = 5.minutes

    packages = DbPackage.find :all,
      :from => 'db_packages pac, db_projects pro',
      :select => 'pac.name, pac.created_at, pro.name AS project_name',
      :conditions => 'pro.id = pac.db_project_id',
      :order => 'created_at DESC, name', :limit => @limit
    projects = DbProject.find :all,
      :select => 'name, created_at',
      :order => 'created_at DESC, name', :limit => @limit

    list = []
    projects.each { |project| list << project }
    packages.each { |package| list << package }
    list.sort! { |a,b| b.created_at <=> a.created_at }

    @list = list[0..@limit-1]
  end


  def added_timestamp
    @project = DbProject.find_by_name( params[:project] )
    @package = DbPackage.find( :first, :conditions =>
      [ 'name=? AND db_project_id=?', params[:package], @project.id ]
    ) if @project
  end


  def latest_updated
    # set automatic action_cache expiry time limit
    response.time_to_live = 5.minutes

    packages = DbPackage.find :all,
      :from => 'db_packages pac, db_projects pro',
      :select => 'pac.name, pac.updated_at, pro.name AS project_name',
      :conditions => 'pro.id = pac.db_project_id',
      :order => 'updated_at DESC, name', :limit => @limit
    projects = DbProject.find :all,
      :select => 'name, updated_at',
      :order => 'updated_at DESC, name', :limit => @limit

    list = []
    projects.each { |project| list << project }
    packages.each { |package| list << package }
    list.sort! { |a,b| b.updated_at <=> a.updated_at }

    @list = list[0..@limit-1]
  end


  def updated_timestamp
    @project = DbProject.find_by_name( params[:project] )
    @package = DbPackage.find( :first, :conditions =>
      [ 'name=? AND db_project_id=?', params[:package], @project.id ]
    ) if @project
  end


  def global_counters
    @users = User.count
    @repos = Repository.count
    @projects = DbProject.count
    @packages = DbPackage.count
  end


  def latest_built
    # set automatic action_cache expiry time limit
    response.time_to_live = 10.minutes

    # TODO: implement or decide to abolish this functionality
  end


  def get_limit
    @limit = 10 if (@limit = params[:limit].to_i) == 0
  end


  def randomize_timestamps

    # ONLY enable on test-/development database!
    # it will randomize created/updated timestamps of ALL packages/projects!
    # this should NOT be enabled for prodution data!
    enable = false
    #

    if enable

      # deactivate automatic timestamps for this action
      ActiveRecord::Base.record_timestamps = false

      projects = DbProject.find(:all)
      packages = DbPackage.find(:all)

      projects.each do |project|
        date_min = Time.utc 2005, 9
        date_max = Time.now
        date_diff = ( date_max - date_min ).to_i
        t = [ (date_min + rand(date_diff)), (date_min + rand(date_diff)) ]
        t.sort!
        project.created_at = t[0]
        project.updated_at = t[1]
        if project.save
          logger.debug "Project #{project.name} got new timestamps"
        else
          logger.debug "Project #{project.name} : ERROR setting timestamps"
        end
      end

      packages.each do |package|
        date_min = Time.utc 2005, 6
        date_max = Time.now - 36000
        date_diff = ( date_max - date_min ).to_i
        t = [ (date_min + rand(date_diff)), (date_min + rand(date_diff)) ]
        t.sort!
        package.created_at = t[0]
        package.updated_at = t[1]
        if package.save
          logger.debug "Package #{package.name} got new timestamps"
        else
          logger.debug "Package #{package.name} : ERROR setting timestamps"
        end
      end

      # re-activate automatic timestamps
      ActiveRecord::Base.record_timestamps = true

      render :text => "ok, done randomizing all timestams."
      return
    else
      logger.debug "tried to execute randomize_timestamps, but it's not enabled!"
      render :text => "this action is deactivated."
      return
    end

  end


end
