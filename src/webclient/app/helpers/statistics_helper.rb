module StatisticsHelper


  def statistics_limit_form( action, title='' )
    out = ''
    out << start_form_tag( nil, :method => :get )
    out << statistics_limit_select( "#{title} " )
    out << hidden_field_tag( 'more', params[:more] )
    out << hidden_field_tag( 'package', @package ) if @package
    out << hidden_field_tag( 'project', @project ) if @project
    out << hidden_field_tag( 'repo', @repo) if @repo
    out << hidden_field_tag( 'arch', @arch) if @arch
    out << image_submit_tag( 'system-search.png' )
    out << image_tag( 'rotating-tail.gif', :border => 0, :style => 'display: none;', :id => 'spinner' )
    out << "</form>"
    out << observe_field( :limit, :update => action,
      :url => { :action  => action, :more => true,
        :project => @project, :package => @package,
        :arch => @arch, :repo => @repo
      },
      :with => "'limit=' + escape(value)", :loading => "Element.show('spinner')",
      :complete => "Element.hide('spinner')"
    )
    return out
  end


  def statistics_limit_select( left_text='', right_text='' )
    out = ''
    out << "#{left_text}"
    out << select_tag( 'limit', options_for_select(
      [['...',10],[25,25],[50,50],[100,100],[250,250],[500,500]])
      )
    out << javascript_tag( "document.getElementById('limit').focus();" )
    out << "#{right_text}"
    return out
  end


  def link_to_package_view( name, project, title='', length=15 )
    link_to image_tag( 'package', :border => 0 ) + " #{shorten_text(name, length)}",
      { :action => 'view', :controller => 'package',
        :package => name, :project => project },
      :title => "Package #{name} #{title}"
  end


  def link_to_project_view( name, title='', length=15 )
    link_to image_tag( 'project', :border => 0 ) + " #{shorten_text(name, length)}",
      { :action => 'view', :controller => 'project',
        :project => name },
      :title => "Project #{name} #{title}"
  end


  def link_to_mainpage
    link_to image_tag( 'start', :border => 0 ) + ' back to main page...',
      :controller => 'statistics'
  end


end
