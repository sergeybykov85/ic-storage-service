import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Char "mo:base/Char";
import Cycles "mo:base/ExperimentalCycles";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Prim "mo:⛔";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Trie "mo:base/Trie";

import Types "./Types";

module {
    public let VERSION = "0.1.1";
    // 1MB
    let MB_IN_BYTES:Int = 1_048_576;

    public func get_memory_in_mb() : Int {
        return _metric_to_mb(Prim.rts_memory_size());
    };

    public func get_heap_in_mb() : Int {
        return _metric_to_mb(Prim.rts_heap_size());
    };

    public func get_cycles_balance() : Int {
        return Cycles.balance();
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
            tags = List.toArray(info.tags);
            buckets = List.toArray(info.buckets);
            active_bucket = info.active_bucket;
            scaling_strategy = info.scaling_strategy;
			created = info.created;
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

    private func _metric_to_mb(v: Nat) : Int {
        let v_in_mb = Float.toInt(Float.abs(Float.fromInt(v) / Float.fromInt(MB_IN_BYTES)));
        return v_in_mb;
    };  

};
