require 'rexml/document'

class Statusmessage < ActiveXML::Base

  default_find_parameter :id

  class << self

    def make_stub( opt )
      logger.debug "--> creating stub element for #{self.name}, arguments: #{opt.inspect}"
      doc = REXML::Document.new
      #doc << XMLDecl.new( 1.0, 'UTF-8', 'no' )
      doc.add_element( REXML::Element.new( 'message' ) )
      doc.root.add_attribute( 'severity', opt[:severity] ) if opt[:severity]
      doc.root.add_text( opt[:message] )
      return doc
    end

  end #self

  def id
    @init_options[:id]
  end
end
