import Cycles "mo:base/ExperimentalCycles";
import Array "mo:base/Array";
import Text "mo:base/Text";
import List "mo:base/List";
import Hash "mo:base/Hash";
import Nat "mo:base/Nat";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Option "mo:base/Option";

import Types "./Types";

shared (installation) actor class ServiceConfig() = this {

	// owner has a super power, do anything inside this actor and assign any list of operators
    stable let OWNER = installation.caller;
	// number of cycles to leave on the canister before taking (withdrawal) all cycles
	stable var remainder_cycles: Nat = 10_000_000_000;

	stable var app_init_cycles: Nat = 100_000_000_000;

	stable var bucket_init_cycles: Nat = 50_000_000_000;

	// operator has enough power, but can't apply a new operator list or change the owner, etc
	stable var operators:[Principal] = [];

	stable var tier_settings : Trie.Trie<Types.ServiceTier, Types.TierSettings> = Trie.empty();
	stable var tier_settings_history : Trie.Trie<Types.ServiceTier, List.List<Types.TierSettings>> = Trie.empty();    


    private func tier_equal(t1: Types.ServiceTier, t2: Types.ServiceTier): Bool  {t1 == t2;};

    /*private func tier_str (t:Types.ServiceTier) : Text {
        switch (t) {
            case (#Free) {"Free"};
            case (#Standard) {"Standard";};
            case (#Advanced) {"Advanced";};
        }
    };*/

    private func tier_hash(t : Types.ServiceTier) : Hash.Hash {
        (switch (t) {
            case (#Free) {1;};
            case (#Standard) {2;};
            case (#Advanced) {3;};
        });
    };

    private func tier_key(id: Types.ServiceTier) : Trie.Key<Types.ServiceTier>  {
         //let s = tier_str(id);
         { key = id; hash = tier_hash id };
    };

    private func tier_settings_get(id : Types.ServiceTier) : ?Types.TierSettings = Trie.get(tier_settings, tier_key(id), tier_equal);
    private func tier_settings_history_get(id : Types.ServiceTier) : ?List.List<Types.TierSettings> = Trie.get(tier_settings_history, tier_key(id), tier_equal);
	
    private func _is_operator(id: Principal) : Bool {
    	Option.isSome(Array.find(operators, func (x: Principal) : Bool { x == id }))
    };

	/**
	* Applies the list of operators for the config service.
	* Allowed only to the owner user
	*/
    public shared ({ caller }) func apply_operators(ids: [Principal]) {
		assert(caller == OWNER);
    	operators := ids;
    };


    public shared ({ caller }) func apply_remainder_cycles(v:Nat) {
		assert(caller == OWNER);
    	remainder_cycles:=v;
    };

    public shared ({ caller }) func apply_app_init_cycles(v:Nat) {
		assert(caller == OWNER);
    	app_init_cycles:=v;
    };

    public shared ({ caller }) func apply_bucket_init_cycles(v:Nat) {
		assert(caller == OWNER);
    	bucket_init_cycles:=v;
    };		

	public query func access_list() : async (Types.AccessList) {
		return { owner = OWNER; operators = operators }
	};

	/**
	* Adds the new tier settings.
	* Allowed only to the owner user or operator.
	*/
    public shared ({ caller }) func apply_tier_settings(t:Types.ServiceTier, settings:Types.TierSettingsArg) {
    	assert(caller == OWNER or _is_operator(caller));
        switch (tier_settings_get(t)) {
            case (?ext) {
                let hist = switch (tier_settings_history_get(t)) {
                    case (?h) { h; };
                    case (null) {List.nil();}
                };
                tier_settings_history := Trie.put(tier_settings_history, tier_key(t), tier_equal, List.push(ext, hist)).0;
            };
            case (null) { };
        };
        tier_settings := Trie.put(tier_settings, tier_key(t),tier_equal, {
            number_of_applications = Option.get(settings.number_of_applications, 1);
		    number_of_repositories = Option.get(settings.number_of_repositories, 1);
		    private_repository_allowed = Option.get(settings.private_repository_allowed, false);
		    nested_directory_allowed = Option.get(settings.nested_directory_allowed, false);
		    created = Time.now();
        }).0;
    };

	public shared ({ caller }) func get_tier_settings_history (t:Types.ServiceTier) : async [Types.TierSettings] {
    	switch (tier_settings_history_get(t)) {
        	case (?h) { List.toArray(h); };
        	case (_) {[];};
      	};
  	};

	public query func get_tier_settings(t:Types.ServiceTier) : async Result.Result<Types.TierSettings, Types.Errors> {
		switch (tier_settings_get(t)){
			case (?s) {
				return #ok(s);
			};
			case (null) {
				return #err(#TierNotFound);	
			};
		}
	};

	/**
	* Returns value of the remainder cycles
	*/
	public query func get_remainder_cycles() : async Nat {
		return remainder_cycles;
	};

	/**
	* Returns value of cycles to be assigned for any new app
	*/
	public query func get_app_init_cycles() : async Nat {
		return app_init_cycles;
	};

	/**
	* Returns value of cycles to be assigned for any new bucket
	*/
	public query func get_bucket_init_cycles() : async Nat {
		return bucket_init_cycles;
	};		         

	system func preupgrade() { 
	};

	system func postupgrade() {
	};

  	public shared func wallet_receive() {
    	let amount = Cycles.available();
    	ignore Cycles.accept(amount);
  	};
	
  	public query func available_cycles() : async Nat {
    	return Cycles.balance();
  	};	
};
