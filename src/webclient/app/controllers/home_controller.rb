class HomeController < ApplicationController

  def index
    unless session[:login]
      @error_message = "There must be a user logged in to show the homepage"
      render :template => 'error'
    end

    logger.debug("Homepage for logged in user: #{session[:login]}")

    @user = Person.find( :login => session[:login] )

    unless @user
      @error_message = "There is no user <b>#{session[:login]}</b> known in the system."
      render :template => 'error'
    end

    session[:tagcloud] ||= :mytags
    logger.debug "Tagcloud switch initialized: Building Tagcloud for #{session[:tagcloud]}"
    @tagcloud ||= Tagcloud.find( session[:tagcloud].to_sym, :user => session[:login] )
  end

end
