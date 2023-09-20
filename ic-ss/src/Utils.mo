import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Char "mo:base/Char";
import Debug "mo:base/Debug";
import Cycles "mo:base/ExperimentalCycles";
import Float "mo:base/Float";
import List "mo:base/List";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Map "mo:base/HashMap";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Option "mo:base/Option";
import Prelude "mo:base/Prelude";
import Principal "mo:base/Principal";
import Prim "mo:⛔";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Trie "mo:base/Trie";

import Types "./Types";
import SHA256 "./Sha256";

module {

    public let FORMAT_DATES_SCRIPT = "<script>let dates = document.getElementsByClassName(\"js_date\"); for (let i=0; i<dates.length; i++) { dates[i].innerHTML = (new Date(dates[i].textContent/1000000).toLocaleString()); } </script>";
    public let ROOT = "/";
    public let DEF_BODY_STYLE = " a { text-decoration: underscore; color:#090909; } body { background-color: #E9FCDF; color:#090909; font-family: helvetica; }";

    let HEX_SYMBOLS =  [
    '0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
    ];

    let NOT_ALLOWED_FOR_NAME = ['\u{22}','/',',','#', '@', '?', '+',';',':','$','=','[',']','~','^','|','<','>','{','}'];
    // 1MB
    let MB_IN_BYTES:Int = 1_048_576;
    
    let PARAM_TOKEN = "token";
    
    let INDEX_ROUTE = "/i/";
    // it is a http route to open/read any type of resource by its ID
    let RESOURCE_ROUTE = "/r/";
    // it is a http route to download resource by its ID
    let DOWNLOAD_ROUTE = "/d/";
    // it is a http route when names insead of ids are used to identify a resource
    //let NAME_BASED_ROUTE = "/ns/";

    private type ResourceUrlArgs = {
        resource_id : Text;
        canister_id : Text;
        network : Types.Network;
        view_mode : Types.ViewMode;
    };

    public func principal_key(id: Principal) : Trie.Key<Principal> = { key = id; hash = Principal.hash id };

    public func text_key(id: Text) : Trie.Key<Text> = { key = id; hash = Text.hash id };

    public func get_resource_id(url : Text) : ?Types.RequestedObject {

        if (Text.startsWith(url, #text RESOURCE_ROUTE) ) {
            return ?{
                path = [_fetch_id_from_uri(url)];
                view_mode = #Open;
                token = _fetch_param_from_uri(url, PARAM_TOKEN);
            };
        };
        if (Text.startsWith(url, #text DOWNLOAD_ROUTE)) {
            return ?{
                path = [_fetch_id_from_uri(url)];
                view_mode = #Download;
                token = _fetch_param_from_uri(url, PARAM_TOKEN);
            };            
        };        
        if (Text.startsWith(url, #text INDEX_ROUTE)) {
            let path = unwrap(Text.stripStart(url, #text INDEX_ROUTE));
            if (path == "" or Text.startsWith(path, #char '?')) {
                return ?{
                    path = [];
                    view_mode = #Index;
                    token = _fetch_param_from_uri(url, PARAM_TOKEN);
                };  
            };
            let no_slash_no_query : [Text] = Iter.toArray(Text.tokens(path, #char '?'));
            let tokens = Array.map<Text, Text>(Iter.toArray(Text.tokens(no_slash_no_query[0] , #char '/')), func (x: Text): Text = un_escape_browser_token(x)  );
            return ?{
                path = tokens;
                view_mode = #Index;
                token = _fetch_param_from_uri(url, PARAM_TOKEN);
            };                
        };

        return null;
    };
    

    private func _fetch_id_from_uri (url: Text): Text {
        let url_split : [Text] = Iter.toArray(Text.tokens(url, #char '/'));
        let last_token : Text = url_split[url_split.size() - 1];
        let filter_query_params : [Text] = Iter.toArray(Text.tokens(last_token, #char '?'));
        return filter_query_params[0];
    };    

    private func un_escape_browser_token (token : Text) : Text {
        Text.replace(Text.replace(token, #text "%20", " "), #text "%2B", "+")
    };


    private func _fetch_param_from_uri (url : Text, param : Text) : ?Text {
        let filter_query_params : [Text] = Iter.toArray(Text.tokens(url, #char '?'));
        if (Array.size(filter_query_params) == 2) {
            var t : ?Text = null;
            Iter.iterate<Text>(Text.split(filter_query_params[1], #text("&")), 
                func(x, _i) {
                    let param_entry = Iter.toArray(Text.split(x, #text("=")));
                    if (Array.size(param_entry) == 2) {
                        if (param_entry[0] == param) t:=?param_entry[1];
                    }
                });
            return t;
        } else return null;
    };    

    private func contains_invalid_symbol (id:Char) : Bool  {
        Option.isSome(Array.find(NOT_ALLOWED_FOR_NAME, func (x: Char) : Bool { x == id } ));
    };

    public func invalid_name (name : Text) : Bool {
        Text.contains(name, #predicate (func(c) {contains_invalid_symbol(c)})  );
    };    

    /**
    * Builds resource url based on specified params (id, network, view mode)
    */
    public func build_resource_url(args : ResourceUrlArgs) : Text {
        let router_id = switch (args.view_mode) {
            case (#Index) {INDEX_ROUTE};
            case (#Open) {RESOURCE_ROUTE};
            case (#Download) {DOWNLOAD_ROUTE};
        };

        switch (args.network){
            case (#Local(location)) return Text.join("",(["http://", args.canister_id, ".", location, router_id, args.resource_id].vals()));
            case (#IC) return Text.join("", (["https://", args.canister_id, ".raw.icp0.io", router_id, args.resource_id].vals()));
        };
    };
    /**
    * Generates hash based on a prefix, current time and suffix (counter).
    * It is used to generate ids.
    * Since the time it is a part pf the hash, then it is difficult to preditc the next id
    */
    public func hash_time_based (prefix : Text, suffix : Nat) : Text {
        let message = SHA256.sha256(Blob.toArray(Text.encodeUtf8(prefix # Int.toText(Time.now()) # Nat.toText(suffix))));
        return to_hex(message);
    };
    /**
    * Generates hash based on a prefix and array of strings
    */
    public func hash (prefix : Text, items : [Text]) : Text {
        let message = SHA256.sha256(Blob.toArray(Text.encodeUtf8(prefix # Text.join("", items.vals()))));
        return to_hex(message);
    };    

    public func get_memory_in_mb() : Int {
        return _metric_to_mb(Prim.rts_memory_size());
    };

    public func get_heap_in_mb() : Int {
        return _metric_to_mb(Prim.rts_heap_size());
    };

    public func get_cycles_balance() : Int {
        return Cycles.balance();
    };

    public func appendTokenParam (url : Text, token : ?Text) : Text {
        if (Option.isNull(token)) return url;
        if (Text.contains(url, #char '?')) {
            return url # "&" # PARAM_TOKEN # "=" # unwrap(token);
        };
        return url # "?" # PARAM_TOKEN # "=" # unwrap(token);
    };

    public func subText(value : Text, indexStart: Nat, indexEnd : Nat) : Text {
        if (indexStart == 0 and indexEnd >= value.size()) {  return value; };
        if (indexStart >= value.size()) {
            return "";
        };

        var result : Text = "";
        var i : Nat = 0;
        label l for (c in value.chars()) {
            if (i >= indexStart and i < indexEnd) {
                result := result # Char.toText(c);
            };
            if (i == indexEnd) {
                break l;
            };
            i += 1;
        };
        result;
    };    

    public func join<T>(a: [T], b:[T]) : [T] {
		// Array.append is deprecated and it gives a warning
    	let capacity : Nat = Array.size(a) + Array.size(b);
    	let res = Buffer.Buffer<T>(capacity);
    	for (p in a.vals()) { res.add(p); };
    	for (p in b.vals()) { res.add(p); };
    	Buffer.toArray(res);
    };

    public func include<T>(a: [T], b : T) : [T] {
		// Array.append is deprecated and it gives a warning
    	let capacity : Nat = Array.size(a) + 1;
    	let res = Buffer.Buffer<T>(capacity);
    	for (p in a.vals()) { res.add(p); };
    	res.add(b);        
    	Buffer.toArray(res);
    };    

    /**
    * Builds a "view" object which represents repository entity
    */
    public func repository_view(id:Text, info: Types.Repository) : Types.RepositoryView {
        return {
            id = id;
            access_type = info.access_type;
            name = info.name;
            description = info.description;
            buckets = List.toArray(info.buckets);
            active_bucket = info.active_bucket;
            scaling_strategy = info.scaling_strategy;
			created = info.created;
        };
    };

    /**
    * Builds a "view" object which represents a resource entity.
    * View object includes a http url to the resource
    */
    public func resource_view(id:Text, info: Types.Resource, canister_id : Text, network : Types.Network) : Types.ResourceView {
        return {
            id = id;
            resource_type = info.resource_type;
            http_headers = info.http_headers;
            content_size = info.content_size;
            created = info.created;
            name = info.name;
            ttl = info.ttl;
            url = build_resource_url({
				resource_id = id;
				canister_id = canister_id;
				network = network;
                view_mode = #Open;
			});
        };
    };

    /**
    * Builds a "view" object which represents a customer entity
    */
    public func customer_view(info: Types.Customer) : Types.CustomerView {
        return {
            name = info.name;
            description = info.description;
            identity = info.identity;
            tier = info.tier;
            applications = List.toArray(info.applications);
			created = info.created;
        };
    };

    /**
    * Builds a "view" object which represents repository entity
    */
    public func customerApp_view(id: Principal, info: Types.CustomerApp) : Types.CustomerAppView {
        return {
            id = id;
            name = info.name;
            description = info.description;
            owner = info.owner;
			created = info.created;
        };
    }; 
    /**
    * Generates a hex string based on array of Nat8
    */
    public func to_hex(arr: [Nat8]): Text {
        Text.join("", Iter.map<Nat8, Text>(Iter.fromArray(arr), func (x: Nat8) : Text {
            let c1 = HEX_SYMBOLS[Nat8.toNat(x / 16)];
            let c2 = HEX_SYMBOLS[Nat8.toNat(x % 16)];
            Char.toText(c1) # Char.toText(c2);
        }))
    };

    public func unwrap<T>(x: ?T) : T {
        switch x {
            case null { Prelude.unreachable() };
            case (?x_) { x_ };
        }
    }; 

    private func _metric_to_mb(v: Nat) : Int {
        let v_in_mb = Float.toInt(Float.abs(Float.fromInt(v) / Float.fromInt(MB_IN_BYTES)));
        return v_in_mb;
    };  
              

};
