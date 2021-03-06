require 'rexml/document'

class Tag < ActiveXML::Base
  
  class << self
    
    # redefine make_stub to achieve taglist needs 
    def make_stub( opt )                  
      
      xml = REXML::Document.new
      xml << REXML::XMLDecl.new(1.0, "UTF-8", "no")
      xml.add_element( REXML::Element.new("tags") )
      if opt[:package]
        xml.root.add_attribute REXML::Attribute.new("project", opt[:project])
        xml.root.add_attribute REXML::Attribute.new("package", opt[:package])
      else #package
        xml.root.add_attribute REXML::Attribute.new("project", opt[:project])
      end
      
      opt[:tag].split(" ").each do |tag|
        tag = tag.strip
        #escaping entities is not enough!
        tag.gsub!("\&","&amp;")
        #ActiveRecord::Base.logger.debug "[TAG:] gsub Tag: #{tag}"
        element = REXML::Element.new( 'tag' )
        element.add_attribute REXML::Attribute.new('name', tag)
        xml.root.add_element(element)      
      end
      xml
    end
    
  end #self
  
  #TODO: I'll remove it later. 
  #  def update (params)
  #    
  #       #logger.debug "saving #{object.inspect}"
  #        #url = substituted_uri_for( object )
  #        url = URI.parse "http://localhost:3001/user/#{params[:user]}/tags/#{params[:project]}/#{params[:package]}"
  #
  #        self.class.transport.http_do 'put', url, self.dump_xml
  #        return true     
  #      end
  
end #class
