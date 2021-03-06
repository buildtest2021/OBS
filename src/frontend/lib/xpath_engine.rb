class XpathEngine

  require 'rexml/parsers/xpathparser'

  class Error < Exception; end
  class IllegalXpathError < Error; end

  def initialize
    @lexer = REXML::Parsers::XPathParser.new

    @tables = {
      'package' => 'db_packages',
      'project' => 'db_projects',
      'person' => 'users',
    }

    @attribs = {
      'db_packages' => {
        '@project' => {:cpart => 'db_projects.name'},
        '@name' => {:cpart => 'db_packages.name'},
        'title' => {:cpart => 'db_packages.title'},
        'description' => {:cpart => 'db_packages.description'},
        'person/@userid' => {:cpart => 'users.login', :joins => 
          ['LEFT JOIN package_user_role_relationships ON db_packages.id = package_user_role_relationships.db_package_id',
           'LEFT JOIN users ON users.id = package_user_role_relationships.bs_user_id']
        }
      },
      'db_projects' => {
        '@name' => {:cpart => 'db_projects.name'},
        'title' => {:cpart => 'db_projects.title'},
        'description' => {:cpart => 'db_projects.description'},
        'person/@userid' => {:cpart => 'users.login', :joins => [
          'LEFT JOIN project_user_role_relationships ON db_projects.id = project_user_role_relationships.db_project_id',
          'LEFT JOIN users ON users.id = project_user_role_relationships.bs_user_id'
        ]},
        'repository/@name' => {:cpart => 'repositories.name'},
        'repository/path/@project' => {:cpart => 'path_projects.name', :joins => [
          'LEFT JOIN path_elements ON repositories.id = path_elements.parent_id',
          'LEFT JOIN repositories AS path_repos ON path_elements.repository_id = path_repos.id',
          'LEFT JOIN db_projects AS path_projects ON path_projects.id = path_repos.db_project_id'
        ]}
      }
    }

    @operators = [:eq, :and, :or, :neq]

    @base_table = ""
    @conditions = [1]
    @condition_values = []
    @joins = []
  end

  def logger
    RAILS_DEFAULT_LOGGER
  end

  def find(xpath)
    logger.debug "---------------------- parsing xpath: #{xpath} -----------------------"

    @stack = @lexer.parse xpath
    logger.debug "starting stack: #{@stack.inspect}"

    if @stack.shift != :document
      raise IllegalXpathError, "xpath expression has to begin with root node"
    end

    if @stack.shift != :child
      raise IllegalXpathError, "xpath expression has to begin with root node"
    end

    @stack.shift
    @stack.shift
    @base_table = @tables[@stack.shift]

    while @stack.length > 0
      token = @stack.shift
      logger.debug "next token: #{token.inspect}"
      case token
      when :ancestor
      when :ancestor_or_self
      when :attribute
      when :descendant
      when :descendant_or_self
      when :following
      when :following_sibling
      when :namespace
      when :parent
      when :preceding
      when :preceding_sibling
      when :self
        raise IllegalXpathError, "axis '#{token}' not supported"
      when :child
        if @stack.shift != :qname
          raise IllegalXpathError, "non :qname token after :child token: #{token.inspect}"
        end
        namespace = @stack.shift
        node = @stack.shift
      when :predicate
        parse_predicate @stack.shift
      else
        raise IllegalXpathError, "unhandled token '#{token.inspect}'"
      end
    end

    logger.debug "-------------------- end parsing xpath: #{xpath} ---------------------"

    model = nil
    case @base_table
    when 'db_packages'
      model = DbPackage
      includes = [:db_project]
    when 'db_projects'
      model = DbProject
      includes = [:repositories]
    else
      logger.debug "strange base table: #{@base_table}"
    end

    cond_ary = [@conditions.flatten.uniq.join(" AND "), @condition_values].flatten

    logger.debug "-- cond_ary: #{cond_ary.inspect} --"
    return model.find(:all, :include => includes, :joins => @joins.flatten.uniq.join(" "),
                      :conditions => cond_ary )
  end

  def parse_predicate(stack)
    logger.debug "------------------ predicate ---------------"
    logger.debug "-- pred_array: #{stack.inspect} --"

    while stack.length > 0
      token = stack.shift
      case token
      when :function
        fname = stack.shift
        fname_int = "xpath_func_"+fname.gsub(/-/, "_")
        if not respond_to? fname_int
          raise IllegalXpathError, "unknown xpath function '#{fname}'"
        end
        __send__ fname_int, *(stack.shift)
      when *@operators
        opname = token.to_s
        opname_int = "xpath_op_"+opname
        if not respond_to? opname_int
          raise IllegalXpathError, "unhandled xpath operator '#{opname}'"
        end
        __send__ opname_int, *(stack)
        stack = []
      when :child
        stack.shift if stack[0] == :any
      else
        raise IllegalXpathError, "illegal token '#{token.inspect}'"
      end
    end

    logger.debug "-------------- predicate finished ----------"
  end

  def evaluate_expr(expr)
    table = @base_table
    a = Array.new
    while expr.length > 0
      token = expr.shift
      case token
      when :child
        expr.shift #:qname token
        expr.shift #namespace
        a << expr.shift
      when :attribute
        expr.shift #:qname token
        expr.shift #namespace
        a << "@"+expr.shift
      when :literal
        @condition_values << expr.shift
        return "?"
      else
        raise IllegalXpathError, "illegal token: '#{token.inspect}'"
      end
    end
    key = a.join "/"
    raise IllegalXpathError, "unable to evaluate '#{key}'" unless @attribs[table].has_key? key
    logger.debug "-- found key: #{key} --"
    if @attribs[table][key][:joins]
      @joins << @attribs[table][key][:joins]
    end

    return @attribs[table][key][:cpart]
  end

  def xpath_op_eq(lv, rv)
    logger.debug "-- xpath_op_eq(#{lv.inspect}, #{rv.inspect}) --"

    lval = evaluate_expr(lv)
    rval = evaluate_expr(rv)

    condition = "#{lval} = #{rval}"
    logger.debug "-- condition: [#{condition}]"

    @conditions << condition
  end

  def xpath_op_neq(lv, rv)
    logger.debug "-- xpath_op_neq(#{lv.inspect}, #{rv.inspect}) --"

    lval = evaluate_expr(lv)
    rval = evaluate_expr(rv)

    condition = "#{lval} != #{rval}"
    logger.debug "-- condition: [#{condition}]"

    @conditions << condition
  end

  def xpath_op_and(lv, rv)
    logger.debug "-- xpath_op_and(#{lv.inspect}, #{rv.inspect}) --"

    parse_predicate(lv)
    lv_cond = @conditions.pop
    parse_predicate(rv)
    rv_cond = @conditions.pop

    condition = "(#{lv_cond} AND #{rv_cond})"
    logger.debug "-- condition: [#{condition}]"

    @conditions << condition
  end

  def xpath_op_or(lv, rv)
    logger.debug "-- xpath_op_and(#{lv.inspect}, #{rv.inspect}) --"

    parse_predicate(lv)
    lv_cond = @conditions.pop
    parse_predicate(rv)
    rv_cond = @conditions.pop

    condition = "(#{lv_cond} OR #{rv_cond})"
    logger.debug "-- condition: [#{condition}]"

    @conditions << condition
  end 

  def xpath_func_contains(haystack, needle)
    logger.debug "-- xpath_func_contains(#{haystack.inspect}, #{needle.inspect}) --"

    hs = evaluate_expr( haystack )
    ne = evaluate_expr( needle )

    condition = "#{hs} LIKE CONCAT('%',#{ne},'%')"
    logger.debug "-- condition : [#{condition}]"

    @conditions << condition
  end

  def xpath_func_not(expr)
    logger.debug "-- xpath_func_contains(#{expr}) --"

    parse_predicate(expr)
    cond = @conditions.pop

    condition = "(NOT #{cond})"
    logger.debug "-- condition : [#{condition}]"

    @conditions << condition
  end

  def xpath_func_starts_with(x, y)
    logger.debug "-- xpath_func_starts_with(#{x.inspect}, #{y.inspect}) --"

    s1 = evaluate_expr(x)
    s2 = evaluate_expr(y)

    condition = "#{s1} LIKE CONCAT(#{s2},'%')"
    logger.debug "-- condition: [#{condition}]"

    @conditions << condition 
  end 

  def xpath_func_ends_with(x, y)
    logger.debug "-- xpath_func_ends_with(#{x.inspect}, #{y.inspect}) --"

    s1 = evaluate_expr(x)
    s2 = evaluate_expr(y)

    condition = "#{s1} LIKE CONCAT('%',#{s2})"
    logger.debug "-- condition: [#{condition}]"

    @conditions << condition 
  end 
end
