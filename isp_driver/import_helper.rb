module ISPDriver
    module InputsHandler
        def self.handle field
            case field[:type]
            when 'select'
                "M|list|#{field[:label]}|#{field[:values].map{|v| v[:value]}.join(',')}"
            when 'text'
                "O|text|#{field[:label]}"
            when 'slider'
                "M|range|#{field[:label]}|#{field[:min]}..#{field[:max]}|#{field[:min]}"
            when 'value'
                "#{field[:value]}"
            end
        end
    end
    class Client
        def list_products
            r = @billmgr.post({
                auth: @base_params[:auth],
                func: 'vds.order'
            })

            products = JSON.parse(r)["form"][0]["formItems"].last[0]["rows"]
            puts "|  ID\t|\t\tName\t\t\t| Price"
            puts "+======================================================+"
            products.each do | product |
                puts "| #{product["pricelist"]["v"]}\t| #{product["desc"]["v"]}\t\t| #{product['price']['v'][/\w+.\w+/].to_f}"
            end
            puts
        end
        # Syncing Addons, OS templates, and
        def sync_product plan_id
            r = @billmgr.post({
                auth: @base_params[:auth],
                func: 'vds.order.pricelist',
                elid: nil,
                datacenter: 1,
                snext: 'ok',
                skipbasket: nil,
                newbasket: nil,
                stylesheet: nil,
                itemtype: nil,
                period: 1,
                pricelist: plan_id,
                clicked_button: 'order',
                progressid: false,
                sok: 'ok',
                sfrom: 'ajax',
                operafake: 1571087025381
            })

            data = JSON.parse(r.to_s)["form"][0]["formItems"]
            result = data.inject([]) do |res, addon|
                addon = addon.first
                unless addon.nil? then
                    case addon['type']
                    when 'select'
                        el = {
                            type: addon['type'],
                            label: addon['label'],
                            field: addon['fieldname'],
                            values: addon['slist'].map do |el|
                                {key: el['key'], value: el['value'], depend: el['depend']}
                            end
                        }
                        el["depend"] = addon['dependMaster'] if addon['dependMaster'] != ""
                    when 'text'
                        el = {
                            type: addon['type'],
                            label: addon['label'],
                            field: addon['fieldname']
                        }
                    when 'slider'
                        el = {
                            type: addon['type'],
                            label: addon['label'],
                            field: addon['fieldname'],
                            min: addon['min'],
                            max: addon['max'],
                            step: addon['step']
                        }
                    end
                    res << el
                else
                    res
                end
            end
            result << { type: 'value', field: 'id', value: plan_id, label: 'Pricelist ID' }

            return result

            template = result.compact.map do | field |
                {field[:field] => InputsHandler.handle(field)}
            end.reduce(Hash.new, :merge)

            isp_vars = result.compact.inject({}) do |n, field|
                print "Field: #{field[:label]}. Set default? [y/n] "
                if field[:type] == 'value' || STDIN.gets.chomp == 'y' then
                    n[field[:field].upcase] =
                        case field[:type]
                        when 'value'
                            field[:value]
                        when 'slider'
                            print "Choose value between #{field[:min]} and #{field[:max]} with step #{field[:step]}: "
                            STDIN.gets.chomp.to_i
                        when 'select'
                            puts "Choose value:"
                            field[:values].each_with_index do | el, i |
                                puts "\t- #{i}) #{el[:value]}"
                            end
                            field[:values][STDIN.gets.chomp.to_i][:key]
                        when 'text'
                            print "Enter value: "
                            STDIN.gets.chomp
                        end
                else
                    n[field[:field].upcase] = "$#{field[:field].upcase}"
                end
                n
            end
            puts
            
            template = {
                "ISP_VARS" => isp_vars,
                "ISP_RAW_DATA" => Base64::encode64(JSON.generate(template)).chomp
            }

            template.to_one_template
        end
    end
end

class Hash
    def to_one_template
        result = ""
        self.each do | key, value |
            key = key.to_s.upcase
            if value.class == String || value.class == Integer then
                result += "#{key.upcase}=\"#{value.to_s.gsub("\"", "\\\"")}\"\n"
            elsif value.class == Hash then
                result += "#{key.upcase}=[\n"
                size = value.size - 1
                value.each_with_index do | el, i |
                    result += "  #{el[0].upcase}=\"#{el[1].to_s.gsub("\"", "\\\"")}\"#{i == size ? '' : ",\n"}"
                end
                result += " ]\n"
            elsif value.class == Array then
                value.each do | el |
                    result += { key => el}.to_one_template + "\n"
                end
            end
        end
        result.chomp!
    end
end