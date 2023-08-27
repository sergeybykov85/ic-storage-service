import Cycles "mo:base/ExperimentalCycles";
import Array "mo:base/Array";
import List "mo:base/List";
import Iter "mo:base/Iter";
import Map "mo:base/HashMap";
import Nat "mo:base/Nat";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Timer "mo:base/Timer";
import Text "mo:base/Text";
import Option "mo:base/Option";

import DataBucket "DataBucket";
import Types "./Types";
import Utils "./Utils";

shared  (installation) actor class Application(initArgs : Types.ApplicationArgs) = this {

    let OWNER = installation.caller;

 	stable var operators = initArgs.operators;
	stable var cycles_bucket_init = initArgs.cycles_bucket_init;
	stable var tier  = initArgs.tier;

	stable var repositories : Trie.Trie<Text, Types.Repository> = Trie.empty();

	let management_actor : Types.ICManagementActor = actor "aaaaa-aa";

    private func repository_get(id : Text) : ?Types.Repository = Trie.get(repositories, Utils.text_key(id), Text.equal);	

	public shared query func initParams() : async (Types.ApplicationArgs) {
		return initArgs;
	};		
	/**
	* Applies list of operators for the storage service
	*/
    public shared ({ caller }) func apply_operators(ids: [Principal]) {
    	assert(caller == OWNER);
    	operators := ids;
    };

    public shared ({ caller }) func apply_tier (v: Types.ServiceTier) {
    	assert(caller == OWNER);
    	tier := v;
    };	

    public shared ({ caller }) func apply_cycles_bucket_init(v: Nat) {
		assert(caller == OWNER or _is_operator(caller));
    	cycles_bucket_init:=v;
    };	

	public shared ({ caller }) func access_list() : async (Types.AccessList) {
		assert(caller == OWNER or _is_operator(caller));
		return { owner = OWNER; operators = operators };
	};

	/**
	* Registers a new repository. 
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func register_repository (name : Text, description : Text, cycles : ?Nat) : async Result.Result<Text, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		let next_id = Trie.size(repositories) + 1;
		let cycles_assign = Option.get(cycles, cycles_bucket_init);
		
		// first vision how to create "advanced bucket name" to have some extra information
		let bucket_name = debug_show({
			application = Principal.fromActor(this);
			repository_name = name;
			bucket = "bucket_1";
		});
		// create a new bucket
		let bucket = await _register_bucket([caller], bucket_name, cycles_assign);

		// generate repository id
		let hex = Utils.hash_time_based(Principal.toText(Principal.fromActor(this)), next_id);

		let repo : Types.Repository = {
			var name = name;
			var description = description;
			var active_bucket = bucket;
			var buckets = List.push(bucket, null);
			created = Time.now();
		};
		repositories := Trie.put(repositories, Utils.text_key(hex), Text.equal, repo).0;
		return #ok(hex);
	};

	/**
	* Removes a  repository. All bucket are also removed, cycles are being sent to the application canister.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_repository (repository_id : Text) : async Result.Result<Text, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));		
		switch (repository_get(repository_id)) {
			case (?repo) {
				for (bucket_id in List.toIter(repo.buckets)){
					let bucket = Principal.fromText(bucket_id);
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					// send cycles to "application canister" in case of removing a bucket canister
					await bucket_actor.withdraw_cycles({to = Principal.fromActor(this); remainder_cycles = ?10_000_000_000});
					await management_actor.stop_canister({canister_id = bucket});
					await management_actor.delete_canister({canister_id = bucket});
				};
				repositories := Trie.remove(repositories, Utils.text_key(repository_id), Text.equal).0;
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Removes a bucket from the existing repository. Active bucket can't be removed.
	* The cycles from the bucket are being sent to the application canister
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_bucket (repository_id : Text, bucket_id: Text) : async Result.Result<Text, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		switch (repository_get(repository_id)) {
			case (?repo) {
				if (repo.active_bucket == bucket_id) return #err(#OperationNotAllowed);
				if (Option.isSome(List.find(repo.buckets, func (x: Text) : Bool { x == bucket_id }))) {
					let bucket = Principal.fromText(bucket_id);
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					await bucket_actor.withdraw_cycles({to = Principal.fromActor(this); remainder_cycles = ?10_000_000_000});				
					await management_actor.stop_canister({canister_id = bucket});
					await management_actor.delete_canister({canister_id = bucket});
					// exclude bucket id
					repo.buckets := List.mapFilter<Text, Text>(repo.buckets,
						func bk = if (bk == bucket_id) { null } else { ?bk });
					return #ok(bucket_id);
				} else {
					// no such bucket
					return #err(#NotFound);
				}
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Registers  a new bucket inside the repo and sets this backet as an active one. 
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func new_bucket (repository_id : Text, cycles : ?Nat) : async Result.Result<Text, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		switch (repository_get(repository_id)) {
			case (?repo) {
				let cycles_assign = Option.get(cycles, cycles_bucket_init);
				let bucket_name = debug_show({
					application = Principal.fromActor(this);
					repository_name = repo.name;
					bucket = "bucket_"#Nat.toText(List.size(repo.buckets) + 1);
				});
				let bucket = await _register_bucket([caller], bucket_name, cycles_assign);
				repo.buckets := List.push(bucket, repo.buckets);
				// set the new bucker as an active one
				repo.active_bucket := bucket;
				return #ok(bucket);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Registers  a new bucket inside the repo and sets this backet as an active one. 
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func set_active_bucket (repository_id : Text, bucket_id : Text) : async Result.Result<Text, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		switch (repository_get(repository_id)) {
			case (?repo) {
				switch (List.find(repo.buckets, func (x: Text) : Bool { x == bucket_id })) {
					case (?bucket) {
						repo.active_bucket := bucket;
						return #ok(bucket);
					};
					case (null) {
						// no bucket registered, rejected
						return #err(#NotFound);
					};
				};
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};
	/**
	* Registers  a new folder (empty) in the active bucket of the specified repository.  
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func new_directory(repository_id : Text, name : Text) : async Result.Result<Types.IdUrl, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));		
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				await bucket_actor.new_directory(name);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};	

	/**
	* Stores a resource (till 2 mb) in the specified repository
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func store_resource(repository_id : Text, content : Blob, resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				await bucket_actor.store_resource(content, resource_args);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	public query func get_repository_records() : async [Types.RepositoryView] {
		return Iter.toArray(Iter.map (Trie.iter(repositories), 
			func (i: (Text, Types.Repository)): Types.RepositoryView {Utils.repository_view(i.0, i.1)}));
	};

	public query func get_repository(id:Text) : async Result.Result<Types.RepositoryView, Types.Errors> {
		switch (repository_get(id)){
			case (?repo) {
				return #ok(Utils.repository_view(id, repo));
			};
			case (null) {
				return #err(#NotFound);	
			};
		}
	};

	private func _is_operator(id: Principal) : Bool {
    	Option.isSome(Array.find(operators, func (x: Principal) : Bool { x == id }))
    };

	/**
	* Deploys new bucket canister and returns its id
	*/
	private func _register_bucket(operators : [Principal], name:Text, cycles : Nat): async Text {
		Cycles.add(cycles);
		let bucket_actor = await DataBucket.DataBucket({
			// apply the user account as operator of the bucket
			name = name;
			operators = operators;
			network = initArgs.network;
		});

		let bucket_principal = Principal.fromActor(bucket_actor);
		// IC Application is a controller of the bucket. but other users could be added here
		ignore management_actor.update_settings({
			canister_id = bucket_principal;
			settings = {
				controllers = ? [Principal.fromActor(this)];
				freezing_threshold = ?2_592_000;
				memory_allocation = ?0;
				compute_allocation = ?0;
			};
		});
		return Principal.toText(bucket_principal);
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
