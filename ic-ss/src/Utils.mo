import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Char "mo:base/Char";
import Debug "mo:base/Debug";
import ExperimentalCycles "mo:base/ExperimentalCycles";
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

    let HEX_SYMBOLS =  [
    '0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
    ];
    // 1MB
    let MB_IN_BYTES:Int = 1_048_576;
   
   
    // it is a http route to open/read any type of resource by its ID
    let RESOURCE_ROUTE = "/r/";
    // it is a http route to download resource by its ID
    let DOWNLOAD_ROUTE = "/d/";
    // it is a http route when names insead of ids are used to identify a resource
    let NAME_BASED_ROUTE = "/ns/";

    private type ResourceUrlArgs = {
        resource_id : Text;
        canister_id : Text;
        network : Types.Network;
        view_mode : Types.ViewMode;
    };

    public func principal_key(id: Principal) : Trie.Key<Principal> = { key = id; hash = Principal.hash id };

    public func text_key(id: Text) : Trie.Key<Text> = { key = id; hash = Text.hash id };

    /**
    * Builds resource url based on specified params (id, network, view mode)
    */
    public func build_resource_url(args : ResourceUrlArgs) : Text {
        let router_id = switch (args.view_mode) {
            case (#Names) {NAME_BASED_ROUTE};
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
        return ExperimentalCycles.balance();
    };
    /**
    * Builds a "view" object which represents repository entity
    */
    public func repository_view(id:Text, info: Types.Repository) : Types.RepositoryView {
        return {
            id = id;
            name = info.name;
            description = info.description;
            buckets = List.toArray(info.buckets);
            active_bucket = info.active_bucket;
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
            content_size = info.content_size;
            created = info.created;
            name = info.name;
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
