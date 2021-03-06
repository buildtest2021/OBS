class Repository < ActiveRecord::Base

  belongs_to :db_project

  has_many :path_elements, :foreign_key => 'parent_id', :dependent => :delete_all, :order => "position"
  has_many :links, :class_name => "PathElement", :foreign_key => 'repository_id'
  has_many :download_stats

  has_and_belongs_to_many :architectures


  class << self
    def find_by_name(name)
      find :first, :conditions => ["name = BINARY ?", name]
    end

    def find_by_project_and_repo_name( project, repo )
      result = find :first, :include => :db_project,
        :conditions => ["db_projects.name = BINARY ? AND repositories.name = BINARY ? AND ISNULL(remote_project_name)", project, repo]

      return result unless result.nil?

      #no local repository found, check if remote repo possible
      fragments = project.split /:/
      local_project = String.new
      remote_project = nil
      
      while fragments.length > 0
        remote_project = [fragments.pop, remote_project].compact.join ":"
        local_project = fragments.join ":"
        logger.debug "checking local project #{local_project}, remote_project #{remote_project}"
        if (lpro = DbProject.find_by_name local_project)
          if not lpro.remoteurl.nil?
            return find_or_create_by_db_project_id_and_name_and_remote_project_name(lpro.id, repo, remote_project)
          end
        end
      end

      return nil
    end
  end

  #returns a list of repositories that include path_elements linking to this one
  #or empty list
  def linking_repositories
    return [] if links.size == 0
    links.map {|l| l.repository}
  end
end
