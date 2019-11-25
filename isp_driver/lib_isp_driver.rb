ONE_LOCATION = ENV["ONE_LOCATION"] if !defined?(ONE_LOCATION)

if !ONE_LOCATION
    RUBY_LIB_LOCATION = "/usr/lib/one/ruby" if !defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION      = "/etc/one/" if !defined?(ETC_LOCATION)
else
    RUBY_LIB_LOCATION = ONE_LOCATION + "/lib/ruby" if !defined?(RUBY_LIB_LOCATION)
    ETC_LOCATION      = ONE_LOCATION + "/etc/" if !defined?(ETC_LOCATION)
end

$: << RUBY_LIB_LOCATION
# require 'opennebula'

require 'rest-client'
require 'json'
require 'base64'
require 'nokogiri'

module ISPDriver
    def self.vm_host vm
        history = vm.to_hash['VM']["HISTORY_RECORDS"]['HISTORY'] # Searching hostname at VM allocation history
        history = history.last if history.class == Array # If history consists of 2 or more lines - returns last
        return history['HID']
    rescue
        return nil # Returns NilClass if did not found anything - possible if vm is at HOLD or PENDING state
    end
    
    class Client
        def initialize host_id
            @host = OpenNebula::Host.new_with_id(host_id, OpenNebula::Client.new)
            @host.info!

            @base_url   = @host['//BASE_URL'] # @host[TEMPLATE/BILLMGR]
            @username   = @host['//USERNAME'] # @host[TEMPLATE/LOGIN]
            @password   = @host['//PASSWORD'] # @host[TEMPLATE/PASSWORD]
            @datacenter = @host['//DATACENTER']

            @billmgr = RC.new(@base_url + '/billmgr', verify_ssl: false)

            r = @billmgr.get(params: {  out: 'json', func: 'auth', username: @username, password: @password    })
            @base_params = {   auth: JSON.parse(r.to_s)['doc']['auth']['$id'], out: 'json', func: nil   }

            @vmmgr = nil
            @vmmgr_data = {}
        rescue => e
            p e.message
        end
        def order params
            r = @billmgr.get(params: @base_params.merge(
                func: 'vds.order.param',
                period: 1,
                newbasket: nil,
                stylesheet: nil,
                elid: nil,
                itemtype: nil,
                skipbasket: nil,
                clicked_button: 'finish',
                progressid: false,
                sok: 'ok',
                sfrom: 'ajax'
            ).merge(params))

            r = @billmgr.get(params: @base_params.merge(
                func: 'order'
            ))
            basket = JSON.parse(r)['doc']['list'].select{|el|el['$name'] == 'openlist'}.last['elem'].last['id']["$"]
            r = @billmgr.get(params: @base_params.merge(
                func: 'basket',
                elid: nil,
                stylesheet: nil,
                id: basket,
                clicked_button: 'free',
                progressid: false,
                sok: 'ok',
                sfrom: 'ajax'
            ))
            r = @billmgr.post(auth: @base_params[:auth], func: 'vds', sfrom: 'ajax', lang: 'en')
            JSON.parse(r.to_s)['content'].first['id']['v']
        ensure
            STDERR.puts(JSON.pretty_generate(@base_params.merge(
                func: 'vds.order.param',
                datacenter: 1,
                period: 1,
                newbasket: nil,
                stylesheet: nil,
                elid: nil,
                itemtype: nil,
                skipbasket: nil,
                clicked_button: 'finish',
                progressid: false,
                sok: 'ok',
                sfrom: 'ajax'
            ).merge(params)))
        end
        def load_vm_manager elid
            return if elid == @vmmgr_data[:deploy_id]
            r = JSON.parse(
                @billmgr.get(params: @base_params.merge(
                    func: 'service.instruction.html', elid: elid, lang: 'en', out: 'json'
                ))
            )['doc']['body']['$']
            doc = Nokogiri::HTML(r) do | config |
                config.nonet || config.noblanks
            end
            vmmgr_set, fields = doc.xpath('//ul').last.xpath('li'), [:url, :username, :password]
            @vmmgr_data = vmmgr_set.each_with_index.inject({}) do |res, pair|
                element, index = pair
                res[fields[index]] = element.children.last.text.strip
                res
            end
            @vmmgr = RC.new(@vmmgr_data[:url])
            r = JSON.parse(@vmmgr.get(params: {out: 'json', func: 'auth'}.merge(@vmmgr_data)))
            @vmmgr_data = { auth: r['doc']['auth']['$'] }
            r = JSON.parse(@vmmgr.get(params: @vmmgr_data.merge(func: 'vm')))
            @vmmgr_data[:elid] = r['content'].select{|el| el['name']['v'] = "vm#{elid}" }.last['id']['v']
            @vmmgr_data[:deploy_id] = elid
        rescue
            "[ISPDriverError] VM is not found"
        end

        # VM actions
        def invoke action, vm
            vm = OpenNebula::VirtualMachine.new_with_id(vm, OpenNebula::Client.new)
            vm.info!
            
            elid = vm.deploy_id
            load_vm_manager elid

            send(action)
        end
        def poweroff
            @vmmgr.get(params: @vmmgr_data.merge(func: 'vm.stop'))
        end
        def resume
            @vmmgr.get(params: @vmmgr_data.merge(func: 'vm.start'))
        end
        def reboot
            @vmmgr.get(params: @vmmgr_data.merge(func: 'vm.restart'))            
        end
        def passwd deploy_id, pass
            load_vm_manager deploy_id
            @vmmgr.post(
                func: 'vm.chpasswd',
                auth: @vmmgr_data[:auth],
                elid: @vmmgr_data[:elid],
                password: pass,
                confirm: pass,
                clicked_button: 'ok',
                sok: 'ok',
                sfrom: 'ajax'
            )
        end
        def terminate
            r = @billmgr.post(
                func: 'vds.delete',
                auth: @base_params[:auth],
                elid: @vmmgr_data[:deploy_id],
                plid: nil,
                progressid: '_deleteundefined',
                sfrom: 'ajax',
                lang: 'en' 
            )
            r = JSON.parse(r)
            if r['message'].first['status'] == 'error' then
                raise r['warning'][@vmmgr_data[:deploy_id].to_s]['msg']
            else
                return true
            end
        end

        # VM Poll (Monitoring)
        def poll
            r = @billmgr.post(auth: @base_params[:auth], func: 'vds', sfrom: 'ajax', lang: 'en')
            res = JSON.parse(r.to_s)['content']
            res.map! do | el |
                elid = el['id']['v']

                begin
                    raise unless el['item_status']['v'] == 'Active'

                    poll_vm elid
                rescue
                    { 
                        deploy_id: elid, ip: el['ip']['v'], 
                        billing_state: el['item_status']['v'],
                        datacenter_name: el['datacentername']['v'], name: el['domain']['v']
                    }
                end
            end
        end
        def poll_vm deploy_id
            load_vm_manager deploy_id

            data = JSON.parse(@vmmgr.get(params: {auth: @vmmgr_data[:auth], func: 'vm', sfrom: 'ajax'}))['content'].first

            { 
                deploy_id: deploy_id, ip: data['ip']['v'], 
                power_state: data['status']['props'][1]['v'],
                cpu: data['vcpu']['v'], ram: data['mem']['v'],
                drive: data['vdsize']['v'], billing_state: 'Active',
                name: data['domain']['v']
            }
        end
        def generate_poll_data vm, deploy_id            
            return  "   VM = [\n" \
                    "       ID=#{deploy_id},\n" \
                    "       VM_NAME=\"#{vm[:name]}\",\n" \
                    "       DEPLOY_ID=#{vm[:deploy_id]},\n" \
                    "       POLL=\"#{generate_poll(vm, true)}\" ]"
        rescue
            return  ""
        end
        def generate_poll vm, im = false
            def state(bill, power) bill == 'Active' ? (power == 'on' ? 'a' : 'd') : 'p'; rescue '-'; end
            return "STATE=#{state(vm[:billing_state], vm[:power_state])} GUEST_IP=#{vm[:ip]}"
        end
    end

    class RC < RestClient::Resource; end
end