require File.dirname(__FILE__) + '/../test_helper'

class DbProjectTest < Test::Unit::TestCase
  fixtures :db_projects, :db_packages, :repositories, :flags, :users

  def setup
    @project = DbProject.find( 502 )
  end
  
    
  def test_flags_to_axml
    #check precondition
    assert_equal 2, @project.build_flags.size
    assert_equal 2, @project.publish_flags.size
    
    xml_string = @project.to_axml
    #puts xml_string
    
    #check the results
    xml = REXML::Document.new(xml_string)
    assert_equal 1, xml.root.get_elements("/project/build").size
    assert_equal 2, xml.root.get_elements("/project/build/*").size
    
    assert_equal 1, xml.root.get_elements("/project/publish").size
    assert_equal 2, xml.root.get_elements("/project/publish/*").size    
  end
  
  
  def test_add_new_flags_from_xml
    
    #precondition check
    @project.flags.destroy_all
    @project.reload
    assert_equal 0, @project.flags.size
    
    #project is given as axml
    axml = ActiveXML::Base.new(
      "<project name='home:tscholz'>
        <title>tscholz's Home Project</title>
        <description></description> 
        <build> 
          <disabled repository='10.2' arch='i386'/>
        </build>
        <publish>
          <enabled repository='10.2' arch='x86_64'/>
        </publish>
        <debug>
          <disabled repository='10.0' arch='i386'/>
        </debug>
      </project>"
      )
    
    ['build', 'publish', 'debug'].each do |flagtype|
      @project.update_flags(:project => axml, :flagtype => flagtype)
    end
      
    @project.reload
    
    #check results
    assert_equal 1, @project.build_flags.size
    assert_equal 'disabled', @project.build_flags[0].status
    assert_equal '10.2', @project.build_flags[0].repo
    assert_equal 'i386', @project.build_flags[0].architecture.name
    assert_equal 1, @project.build_flags[0].position
    assert_nil @project.build_flags[0].db_package    
    assert_equal 'home:tscholz', @project.build_flags[0].db_project.name
    
    assert_equal 1, @project.publish_flags.size
    assert_equal 'enabled', @project.publish_flags[0].status
    assert_equal '10.2', @project.publish_flags[0].repo
    assert_equal 'x86_64', @project.publish_flags[0].architecture.name
    assert_equal 1, @project.publish_flags[0].position
    assert_nil @project.publish_flags[0].db_package    
    assert_equal 'home:tscholz', @project.publish_flags[0].db_project.name  
    
    assert_equal 1, @project.debug_flags.size
    assert_equal 'disabled', @project.debug_flags[0].status
    assert_equal '10.0', @project.debug_flags[0].repo
    assert_equal 'i386', @project.debug_flags[0].architecture.name
    assert_equal 1, @project.debug_flags[0].position
    assert_nil @project.debug_flags[0].db_package    
    assert_equal 'home:tscholz', @project.debug_flags[0].db_project.name      
    
  end
  
  
  def test_delete_flags_through_xml
    #check precondition
    assert_equal 2, @project.build_flags.size
    assert_equal 2, @project.publish_flags.size
    
    #project is given as axml
    axml = ActiveXML::Base.new(
      "<project name='home:tscholz'>
        <title>tscholz's Home Project</title>
        <description></description> 
      </project>"
      )    
    
    #first update build-flags, should only delete build-flags
    @project.update_flags(:project => axml, :flagtype => 'build')
    assert_equal 0, @project.build_flags.size
        
    #second update publish-flags, should delete publish-flags    
    @project.update_flags(:project => axml, :flagtype => 'publish')
    assert_equal 0, @project.publish_flags.size
    
  end
  
  
  def test_flag_type_mismatch
    #check precondition
    assert_equal 2, @project.build_flags.size    
  
    axml = ActiveXML::Base.new(
      "<project name='home:tscholz'>
        <title>tscholz's Home Project</title>
        <description></description>
        <build>
          <enabled repository='10.2' arch='i386'/>
        </build>      
        <url></url>
        <disable repository='10.0' arch='i386'/>
      </project>"
      )    
  
    assert_raise(RuntimeError){
      @project.flag_compatibility_check(:project => axml)
      }
    
    assert_equal 2, @project.build_flags.size  
  end
  
  
  def test_old_flag_to_build_flag
    #check precondition
    assert_equal 2, @project.build_flags.size    

    axml = ActiveXML::Base.new(
      "<project name='home:tscholz'>
        <title>tscholz's Home Project</title>
        <description></description>    
        <url></url>
        <disable/>
        <disable repository='10.2'/>
        <disable repository='10.2' arch='i386'/>
      </project>"
      )      
      
    @project.old_flag_to_build_flag(:project => axml, :flagtype => 'build')
    assert_equal 3, @project.build_flags.size  
  end
  
  
  def test_store_axml
    #project is given as axml
    axml = ActiveXML::Base.new(
      "<project name='home:tscholz'>
        <title>tscholz's Home Project</title>
        <description></description>
        <debug>
          <disabled repository='10.0' arch='i386'/>
        </debug>    
        <url></url>
        <disable/>
      </project>"
      )
      
    @project.store_axml(axml)
    
    assert_equal 1, @project.build_flags.size
    assert_equal 1, @project.debug_flags.size        
  end  
  
  
  #helper
  def put_flags(flags)
    flags.each do |flag|
      if flag.architecture.nil?
        puts "#{flag} \t #{flag.id} \t #{flag.status} \t #{flag.architecture} \t #{flag.repo} \t #{flag.position}"
      else
        puts "#{flag} \t #{flag.id} \t #{flag.status} \t #{flag.architecture.name} \t #{flag.repo} \t #{flag.position}"
      end
    end
  end  
  
  
end


#TODO delete
#  def test_update_flags
#    
#    puts "build flag count:\t", @project.build_flags.size, "\n" 
#        put_flags(@project.build_flags)
#        
#        puts "\n adding new flag ................."
#        f= BuildFlag.new(:status => 'disable', :repo => '10.2')
#        @project.build_flags << f
#        f.move_to_top    
#        @project.reload
#        
#        f =  BuildFlag.new(:status => 'enabled')
#        @project.build_flags << f
#        f.move_to_top
#        @project.reload
#        put_flags(@project.build_flags)
#        
#        puts "\n to axml ........................."    
#        axml = ActiveXML::Base.new(@project.to_axml.to_s)
#        puts axml.data.to_s
#        
#        puts "\n update flags with the axml ......"
#        ret =  @project.update_flags(:project => axml, :flagtype => "build")
#        #logger.debug "TEESSSTTT"
#        @project.reload
#        put_flags @project.build_flags
#        
##        put_flags(ret)
##        puts ret.size
##        
##        puts "\n get this result as axml ........."
##        puts ".........done"
##        @project.reload
##        axml = ActiveXML::Base.new(@project.to_axml.to_s)
##        
##        puts "\n remove all enabled flags from axml "
##        3.times do 
##          axml.data.root.delete_element "build/enabled"
##        end
##        puts axml.data.to_s
##        
##        puts "\n update flags with the axml"
##        ret =  @project.update_flags(:project => axml, :flagtype => 'BuildFlag')
##        put_flags(ret)
##        puts ret.size         
#  end


