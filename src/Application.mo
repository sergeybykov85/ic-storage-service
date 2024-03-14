import Cycles "mo:base/ExperimentalCycles";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import List "mo:base/List";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Text "mo:base/Text";
import Option "mo:base/Option";

// -- ICS2 core --
import ICS2DataBucket "mo:ics2-core/DataBucket";
import ICS2Utils "mo:ics2-core/Utils";
import ICS2Http "mo:ics2-core/Http";

import Utils "./Utils";
import Types "./Types";

shared  (installation) actor class _Application(initArgs : Types.ApplicationArgs) = this {

    let OWNER = installation.caller;

	let DEF_CSS =  "<style>" # ICS2Utils.DEF_BODY_STYLE #
	".grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; } "#
	".cell { min-height: 100px; border: 1px solid gray; border-radius: 8px; padding: 8px 16px; position: relative; } "#
	".cell_details { min-height: 250px; border: 1px solid gray; border-radius: 8px; padding: 8px 16px; position: relative; } "#
	".tag { color:#0969DA; margin: 0 4px; border: 1px solid #0969DA; border-radius: 8px; padding: 4px 10px; background-color:#B6E3FF;} "#
	".access_tag { color:white; font-size:large; border: 1px solid gray; border-radius: 8px; padding: 8px 16px; position: absolute; right: 20px; top: 1px; background-color:#636466;} </style>";

 	stable var operators = initArgs.operators;
	stable var tier  = initArgs.tier;
	stable var repositories : Trie.Trie<Text, Types.Repository> = Trie.empty();

	stable var configuration_service =  initArgs.configuration_service;

	let management_actor : Types.ICManagementActor = actor "aaaaa-aa";

	// increment counter, internal needs
	stable var _internal_increment : Nat = 0;	

    private func repository_get(id : Text) : ?Types.Repository = Trie.get(repositories, ICS2Utils.text_key(id), Text.equal);	

		
	/**
	* Applies list of operators for the storage service
	*/
    public shared ({ caller }) func apply_operators(ids: [Principal]) {
    	assert(caller == OWNER);
    	operators := ids;
    };

    public shared ({ caller }) func apply_tier (v: Types.Tier) {
    	assert(caller == OWNER);
    	tier :=v;
    };	

	public shared query func access_list() : async (Types.AccessList) {
		return { owner = OWNER; operators = operators };
	};

	/**
	* Sends cycles to the canister. The destination canister must have a method wallet_receive.
	* It is possible to specify the amount of cycles to leave.
	* Yes, it is possible to call IC.deposit_cycles here to send funds, 
	* but the global idea is to use the "methods of the canister from the ecosystem" to extend them by custom logic if needed.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func withdraw_cycles (args : Types.WitdrawArgs) : async () {
		assert(caller == OWNER or _is_operator(caller));

		let destination = Principal.toText(args.to);
		let wallet : Types.Wallet = actor (destination);
		let cycles = Cycles.balance();
		let cycles_to_leave = Option.get(args.remainder_cycles, 0);
		if  (cycles > cycles_to_leave) {
			let cycles_to_send:Nat = cycles - cycles_to_leave;
			Cycles.add<system>(cycles_to_send);
            await wallet.wallet_receive();
		}
	};	

	/**
	* Registers a new repository. 
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func register_repository (args : Types.RepositoryArgs) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		if (ICS2Utils.invalid_name(args.name)) return #err(#InvalidRequest);
		// control number of repositories
		if (Trie.size(repositories) >= tier.options.number_of_repositories) return #err(#TierRestriction);
		let canister_id = Principal.toText(Principal.fromActor(this));	
		let repository_id = ICS2Utils.hash(canister_id, [args.name]);
		// repo name is uniq across application
		switch (repository_get(repository_id)) {
			case (?repo) {return #err(#DuplicateRecord);};
			case (null) {};
		};

		let cycles_assign = switch (args.cycles) {
			case (?c) {c;};
			case (null) {
				let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
				await configuration_actor.get_bucket_init_cycles();	
			};
		};		
		let bucket_counter = 1;
		// first vision how to create "advanced bucket name" to have some extra information
		let bucket_name = debug_show({
			application = Principal.fromActor(this);
			repository_name = args.name;
			bucket = "bucket_"#Nat.toText(bucket_counter);
		});
		let repo : Types.Repository = {
			name = args.name;
			var description = args.description;
			access_type = args.access_type;
			var active_bucket = "";
			var tags = List.fromArray(args.tags);
			var buckets = List.nil();
			var scaling_strategy = Option.get(args.scaling_strategy, #Disabled);
			created = Time.now();
			var access_keys = List.nil();
			var bucket_counter = bucket_counter;
			var last_update = null;
		};

		// create a new bucket
		let bucket = await _register_bucket(repo, [Principal.fromActor(this)], bucket_name, cycles_assign);
		repo.active_bucket:=bucket;
		repo.buckets:=List.push(bucket, repo.buckets);
	

		repositories := Trie.put(repositories, ICS2Utils.text_key(repository_id), Text.equal, repo).0;
		return #ok(repository_id);
	};

	/**
	* Updates an existing repository, just override  description, tags and scaling_strategy if they specified
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func update_repository (repository_id: Text, args : Types.RepositoryUpdateArgs) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);			
		switch (repository_get(repository_id)) {
			case (?repo) {
				if (Option.isSome(args.description)) {
					repo.description:= ICS2Utils.unwrap(args.description);
				};
				if (Option.isSome(args.tags)) {
					repo.tags:= List.fromArray(ICS2Utils.unwrap(args.tags));
				};
				if (Option.isSome(args.scaling_strategy)) {
					repo.scaling_strategy:= ICS2Utils.unwrap(args.scaling_strategy);
				};
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		};
		
	};	

	/**
	* Removes a  repository. All bucket are also removed, cycles are being sent to the application canister.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_repository (repository_id : Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				for (bucket_id in List.toIter(repo.buckets)){
					let bucket = Principal.fromText(bucket_id);
					let ic_storage_wallet : Types.Wallet = actor (bucket_id);

					let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
					let remainder_cycles = await configuration_actor.get_remainder_cycles();
					/**
					*  send cycles to "application canister" in case of removing a bucket canister.
					*  right now, remainder_cycles is a constant, the idea is to leave some funds to process the request
					*/
					await ic_storage_wallet.withdraw_cycles({to = Principal.fromActor(this); remainder_cycles = ?remainder_cycles});
					await management_actor.stop_canister({canister_id = bucket});
					await management_actor.delete_canister({canister_id = bucket});
				};
				repositories := Trie.remove(repositories, ICS2Utils.text_key(repository_id), Text.equal).0;
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	public shared ({ caller }) func apply_html_resource_template (repository_id : Text, template : ?Text) : async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				for (bucket_id in List.toIter(repo.buckets)){
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					ignore await bucket_actor.apply_html_resource_template(template);
				};

				return #ok();
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	public shared ({ caller }) func apply_cleanup_period (repository_id : Text, seconds : Nat) : async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				for (bucket_id in List.toIter(repo.buckets)){
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					ignore await bucket_actor.apply_cleanup_period(seconds);
				};
				return #ok();
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};		

	/**
	* Triggers a cleanup job for the a  repository. If bucket is not specified, then job is triggered for all buckets, otherwise only for the specified bucket.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func clean_up_repository (repository_id : Text, bucket_id : ?Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				let to_process = switch (bucket_id) {
					case (?bucket) {List.filter(repo.buckets, func (b:Text):Bool {b == bucket} );};
					case (null) {repo.buckets;}
				};
				for (bucket_id in List.toIter(to_process)){
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					await bucket_actor.clean_up();
				};
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Applies a scaling strategy on the repository and triger "scaling attempt" (if needed)
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func apply_scaling_strategy_on_repository (repository_id : Text, value : Types.ScalingStarategy) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				repo.scaling_strategy:=value;
				ignore await _execute_scaling_attempt (repo);
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};


	private func _execute_scaling_attempt (repository : Types.Repository) : async Bool {
		let scaling_needed = switch (repository.scaling_strategy) {
			case (#Disabled) {false;};
			case (#Auto memoryThreshold) {
				let bucket_actor : Types.DataBucketActor = actor (repository.active_bucket);
				let bucket_status = await bucket_actor.get_status();
				if (bucket_status.chunks == 0) {
					let ops:Types.MemoryThreshold = switch (memoryThreshold) {
						case (?m) {m;};
						case (null) {
							let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
							await configuration_actor.get_scaling_memory_options();
						};
					};
					(bucket_status.memory_mb >= ops.memory_mb or bucket_status.heap_mb >= ops.heap_mb)
				}
				else  {false}
			};
		};

		if (scaling_needed) {
			let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
			let cycles_assign = await configuration_actor.get_bucket_init_cycles();
			let bucket_counter = repository.bucket_counter + 1;
			let bucket_name = debug_show({
				application = Principal.fromActor(this);
				repository_name = repository.name;
				bucket = "bucket_"#Nat.toText(bucket_counter);
			});

			var access_tokens_opt:?[Types.AccessToken] = null;
			if (List.size(repository.access_keys) > 0) {
				let tokens = List.map(repository.access_keys, func (ac : Types.AccessKey):Types.AccessToken {
					{
						token = ICS2Utils.unwrap(ac.token);
						created = ac.created;
						valid_to = ac.valid_to;
					}
				});
				access_tokens_opt:=?List.toArray(tokens);
			};

			let bucket = await _register_bucket(repository, [Principal.fromActor(this)], bucket_name, cycles_assign);
			repository.buckets := List.push(bucket, repository.buckets);
			repository.bucket_counter :=bucket_counter;
			// set the new bucker as an active one
			repository.active_bucket := bucket;
		};
		return scaling_needed;

	};	

	/**
	* Removes a bucket from the existing repository. Active bucket can't be removed.
	* The cycles from the bucket are being sent to the application canister
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_bucket (repository_id : Text, bucket_id: Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				if (repo.active_bucket == bucket_id) return #err(#OperationNotAllowed);
				if (Option.isSome(List.find(repo.buckets, func (x: Text) : Bool { x == bucket_id }))) {
					let bucket = Principal.fromText(bucket_id);
					let ic_storage_wallet : Types.Wallet = actor (bucket_id);
					let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
					let remainder_cycles = await configuration_actor.get_remainder_cycles();
					await ic_storage_wallet.withdraw_cycles({to = Principal.fromActor(this); remainder_cycles = ?remainder_cycles});				
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
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let cycles_assign = switch (cycles) {
					case (?c) {c;};
					case (null) {
						let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
						await configuration_actor.get_bucket_init_cycles();
					};
				};
				// first version of the name. Other format might be applied later 
				let bucket_counter = repo.bucket_counter + 1;
				let bucket_name = debug_show({
					application = Principal.fromActor(this);
					repository_name = repo.name;
					bucket = "bucket_"#Nat.toText(bucket_counter);
				});
				let bucket = await _register_bucket(repo, [Principal.fromActor(this)], bucket_name, cycles_assign);
				repo.buckets := List.push(bucket, repo.buckets);
				repo.bucket_counter := bucket_counter;
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
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
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
	* Registers a new directory (empty) in the active bucket of the specified repository.  
	* If directory or subdirectory already present, then error is thrown.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func create_directory(repository_id : Text, args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				// control of nested directories
				if  (tier.options.nested_directory_forbidden and  (Option.isSome(args.parent_path) or Option.isSome(args.parent_id) or Text.contains(args.name, #char '/'))) return #err(#TierRestriction);

				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				await bucket_actor.new_directory(true, args);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Registers a new directory (empty) in the active bucket of the specified repository.  
	* If path of the directory is already exists, just return its id, no error.
	* If subpath is exist but other part is absent, then creates "needed path".
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func ensure_directory(repository_id : Text, args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				// control of nested directories
				if  (tier.options.nested_directory_forbidden and  (Option.isSome(args.parent_path) or Option.isSome(args.parent_id) or Text.contains(args.name, #char '/'))) return #err(#TierRestriction);

				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				await bucket_actor.new_directory(false, args);
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
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				let r = await bucket_actor.store_resource(content, resource_args);
				repo.last_update := Option.make(Time.now());
				try {
					ignore await _execute_scaling_attempt (repo);
				}catch (e) {
					// nothing needed for now
				};
				r;
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Stores a chunk of the resource (file)
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func store_chunk(repository_id : Text, content : Blob, binding_key : ?Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				let r = await bucket_actor.store_chunk(content, binding_key);
				repo.last_update := Option.make(Time.now());
				r;
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Build a resources based on the list of previously uploaded chunks.
	* There are two ways to identify chunks that are used to build a final file : by the list of chunk ids or by the binding name , that was used during chunk upload.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func commit_batch(repository_id : Text, details : Types.CommitArgs, resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		// reject invalid data
		if (details.chunks.size() == 0 and Option.isNull(details.binding_key)) return #err(#NotFound);
		switch (repository_get(repository_id)) {
			case (?repo) {
				
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				let r = switch (details.binding_key){
					case (?binding_key) {
						// commint by key
						await bucket_actor.commit_batch_by_key(binding_key, resource_args);
					};
					case (null) {
						// commint by ids
						await bucket_actor.commit_batch(details.chunks, resource_args);						
					};
				};
				repo.last_update := Option.make(Time.now());
				try {
					ignore await _execute_scaling_attempt (repo);
				}catch (e) {
					// nothing needed for now
				};
				r;
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};	

	/**
	* Execute an action on the resource (copy, rename, delete, set ttl).
	* Right now rename of the directory is not supprted, copy of the directory is not suppprted yet.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func execute_action_on_resource(repository_id : Text, target_bucket:?Text, args:Types.ActionResourceArgs) : async Result.Result<(Types.IdUrl), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (Option.get(target_bucket, repo.active_bucket));
				let r = await bucket_actor.execute_action_on_resource(args);
				repo.last_update := Option.make(Time.now());
				r;
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

	public query func get_tier() : async Types.Tier {
		return tier;
	};

	/**
	* Registers a new access key on the specified repository.
	* Returns `id, and secret key`. Namelly the secret key gives the access to repo. There is no other way to get secet key
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func register_access_key(repository_id : Text, args : Types.AccessKeyArgs) : async Result.Result<(Text, Text), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)){
			case (?repo) {
				if (repo.access_type == #Public) return #err(#OperationNotAllowed);


				_internal_increment := _internal_increment + 1;
				let canister_id =  Principal.toText(Principal.fromActor(this));
				let now = Time.now();
				let key_id = ICS2Utils.hash_time_based(canister_id # "access_key", _internal_increment);
				// lets have a long secret
				let secret_token:Text = ICS2Utils.hash(canister_id, [Int.toText(now), args.entropy]) # 
				ICS2Utils.subText(ICS2Utils.hash(repository_id, [Int.toText(now), args.entropy]), 0, 32);
				let ak:Types.AccessKey =  {
					id = key_id;
					name = args.name;
					token = ? secret_token;
					created = now;
					valid_to = args.valid_to;
				};

				repo.access_keys:= List.push(ak, repo.access_keys);

				for (bucket_id in List.toIter(repo.buckets)){
					let bucket = Principal.fromText(bucket_id);
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					ignore await bucket_actor.register_access_token({
						token = secret_token;
						created = now;
						valid_to = args.valid_to;
					});
				};

				return #ok(key_id, secret_token);
			};
			case (null) {
				return #err(#NotFound);	
			};
		}
	};

	/**
	* Deletes an access key from the repo
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_access_key(repository_id : Text, args : Types.AccessKeyArgs) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)){
			case (?repo) {
				if (repo.access_type == #Public) return #err(#OperationNotAllowed);
				let target = List.find(repo.access_keys, func (k:Types.AccessKey):Bool {k.id == args.id});
				if (Option.isNull(target)) return #err(#NotFound);
				let after_remove = List.filter(repo.access_keys, func (k:Types.AccessKey):Bool {k.id != args.id} );
				repo.access_keys:=after_remove;
				for (bucket_id in List.toIter(repo.buckets)){
					let bucket = Principal.fromText(bucket_id);
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					ignore await bucket_actor.remove_access_token(Option.get(ICS2Utils.unwrap(target).token, ""));
				};				
				return #ok(args.id);
			};
			case (null) {
				return #err(#NotFound);	
			};
		}		
	};	
	/**
	* Returns list of access keys for the repo. Secret key is not returned
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func repository_access_keys(id:Text) : async Result.Result<[Types.AccessKey], Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(id)){
			case (?repo) {
				let _protected = List.map<Types.AccessKey,Types.AccessKey>(repo.access_keys, func (k:Types.AccessKey):Types.AccessKey {
					let r : Types.AccessKey = {
						k with token = null;
					};
					r;
				});
				return #ok(List.toArray(_protected));
			};
			case (null) {
				return #err(#NotFound);	
			};
		}		
	};			

	public shared ({ caller }) func repository_details(id:Text) : async Result.Result<Types.RepositoryDetails, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(id)){
			case (?repo) {
				var infos = Buffer.Buffer<Types.BucketInfo>(List.size(repo.buckets));
				var total_files = 0;
				var total_directories = 0;
				for (bucket_id in List.toIter(repo.buckets)){
					let bucket = Principal.fromText(bucket_id);
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					let i = await bucket_actor.get_status();
					total_files:=total_files + i.files;
					total_directories:=total_directories + i.directories;
					infos.add(i);
				};
				return #ok(	{
						id = id;
						name = repo.name;
						access_type = repo.access_type;
						description = repo.description;
						tags = List.toArray(repo.tags);
						buckets = Buffer.toArray(infos);
						total_files = total_files;
						total_directories =  total_directories;		
						active_bucket = repo.active_bucket;
						scaling_strategy = repo.scaling_strategy;
						created = repo.created;						
					}
				);
			};
			case (null) {
				return #err(#NotFound);	
			};
		}
	};


	public shared query func http_request(request : ICS2Http.Request) : async ICS2Http.Response {
		switch (ICS2Utils.get_resource_id(request.url)) {
			case (?r) {
				let path_size = Array.size(r.path);
				let repository_id = switch (r.view_mode) {
					case (#Index) {
						let canister_id = Principal.toText(Principal.fromActor(this));
						if (path_size == 0) {
							ICS2Utils.ROOT;
						} else 	ICS2Utils.hash(canister_id, r.path);
					};
					case (_) { 
						if (path_size == 0) return ICS2Http.not_found();
						r.path[0]; 
					};
				};
				return repository_http_handler(repository_id, r.view_mode);
			};
			case null { return ICS2Http.not_found();};
		};
	};		

	private func _is_operator(id: Principal) : Bool {
    	Option.isSome(Array.find(operators, func (x: Principal) : Bool { x == id }))
    };

    private func repository_http_handler(key : Text, view_mode : Types.ViewMode) : ICS2Http.Response {
		if (key == ICS2Utils.ROOT) {
			return root_view (view_mode);
		};

		switch (repository_get(key)) {
            case (null) { ICS2Http.not_found() };
            case (? v)  {
				///
				let canister_id = Principal.toText(Principal.fromActor(this));
				let root_url = ICS2Utils.build_resource_url({resource_id = ""; canister_id = canister_id; network = initArgs.network; view_mode = #Index});
				var directory_html = "<html><head>"#DEF_CSS#"</head><body>" # "<h2><span><a style=\"margin: 0 5px;\" href=\"" # root_url # "\" >"#ICS2Utils.ROOT#"</a></span>  &#128464; "#v.name#" </h2><hr/><h3>Repositories</h3><div class=\"grid\">";
				
				directory_html:=directory_html # render_repository_details(canister_id, key, v);
				// extra details possible here
				return ICS2Http.success([("content-type", "text/html; charset=UTF-8")], Text.encodeUtf8(directory_html # "</div>"#ICS2Utils.FORMAT_DATES_SCRIPT#"</body></html>"));
			};
        };
    };

    private func root_view (view_mode : Types.ViewMode) : ICS2Http.Response {
		switch (view_mode) {
			case (#Index) {
				let canister_id = Principal.toText(Principal.fromActor(this));
				var directory_html = "<html><head>"#DEF_CSS#"</head><body>" # "<h2>&#128464; Overview &#9757; </h2><hr/><h3>Repositories</h3><div class=\"grid\">";
				for ((id, r) in Trie.iter(repositories)) {
					directory_html:=directory_html # render_repository_overview(canister_id, id, r);
				};
				ICS2Http.success([("content-type", "text/html; charset=UTF-8")], Text.encodeUtf8(directory_html # "</div>"#ICS2Utils.FORMAT_DATES_SCRIPT#"</body></html>"));
			};
			case (_) {ICS2Http.not_found()};
		};
	};

	private func render_repository_overview (canister_id: Text, id:Text, r:Types.Repository) : Text {
		let path = r.name;
		let url = ICS2Utils.build_resource_url({resource_id = path; canister_id = canister_id; network = initArgs.network; view_mode = #Index});
		var resource_html = "<div class=\"cell\">";
		resource_html :=resource_html # "<div>&#128464; <a style=\"font-weight:bold; color:#0969DA;\" href=\"" # url # "\" target = \"_self\">"# r.name # "</a></div>";
		resource_html := resource_html # "<p><i>"# r.description # "</i></p>";
		resource_html := resource_html # "<p><u>Total buckets</u> : "# Nat.toText(List.size(r.buckets)) ;
		if (r.access_type == #Public and r.active_bucket != "") {
			let bucket_url = ICS2Utils.build_resource_url({resource_id = ""; canister_id = r.active_bucket; network = initArgs.network; view_mode = #Index});
			resource_html := resource_html # "<a style=\"float:right; padding-right:10px;\" href=\"" # bucket_url #"\" target = \"_blank\">&#128194; Open active bucket</a>";
		} else	if (r.access_type == #Private) {
			resource_html := resource_html # "<span style=\"float:right; padding-right:10px;\">&#128273;</span>";
		};
		resource_html := resource_html # "</p>";
		resource_html := resource_html # "<p><u>Created</u> : <span class=\"js_date\">"# Int.toText(r.created) # "</span>";
		if (Option.isSome(r.last_update)){
			resource_html := resource_html # "<span style=\"float:right; padding-right:10px;\"><u style=\"padding-left\">Last update</u> : <span class=\"js_date\">"# Int.toText(ICS2Utils.unwrap(r.last_update)) # "</span></span>";
		};
		resource_html := resource_html # "</p>";
		resource_html := resource_html # "<p class=\"access_tag\">"# debug_show(r.access_type) # "</p>";
		if (List.size(r.tags) > 0) {
			let tags_fmt = Text.join("", List.toIter(List.map(r.tags, func (t : Text):Text {"<span class=\"tag\">"#t#"</span>";})));
			resource_html := resource_html # "<p>"# tags_fmt # "</p>";
		};		
		
		return  resource_html # "</div>";	
	};

	private func render_repository_details (canister_id: Text, id:Text, r:Types.Repository) : Text {
		let path = r.name;
		let url = ICS2Utils.build_resource_url({resource_id = path; canister_id = canister_id; network = initArgs.network; view_mode = #Index});
		var resource_html = "<div class=\"cell_details\">";
		resource_html :=resource_html # "<div>&#128464; <a style=\"font-weight:bold; color:#0969DA;\" href=\"" # url # "\" target = \"_self\">"# r.name # "</a></div>";
		resource_html := resource_html # "<p><i>"# r.description # "</i></p>";
		if (List.size(r.tags) > 0) {
			let tags_fmt = Text.join("", List.toIter(List.map(r.tags, func (t : Text):Text {"<span class=\"tag\">"#t#"</span>";})));
			resource_html := resource_html # "<p><u>Tags</u> : "# tags_fmt # "</p>";
		};		
		resource_html := resource_html # "<p><u>Created</u> : <span class=\"js_date\">"# Int.toText(r.created) # "</span></p>";
		if (Option.isSome(r.last_update)){
			resource_html := resource_html # "<p><u>Last update</u> : <span class=\"js_date\">"# Int.toText(ICS2Utils.unwrap(r.last_update)) # "</span></p>";
		};		
		resource_html := resource_html # "<p><u>Total buckets</u> : "# Nat.toText(List.size(r.buckets)) #"</p>" ;
		if (r.access_type == #Public) {
			resource_html := resource_html # "<div class=\"grid\">";
			for (bucket_id in List.toIter(r.buckets)) {
				let bucket_url = ICS2Utils.build_resource_url({resource_id = ""; canister_id = bucket_id; network = initArgs.network; view_mode = #Index});
				let bucket_id_fmt = if (r.active_bucket == bucket_id) {
					"<b>" # bucket_id # "</b>";
				}else {
					bucket_id;
				};
				resource_html := resource_html # "<div style=\"padding: 0 10px;\">bucket id : <a  href=\"" # bucket_url #"\" target = \"_blank\">"#bucket_id_fmt#"</a></div>";
			};
			resource_html := resource_html # "</div>";
		} else	if (r.access_type == #Private) {
			resource_html := resource_html # "<span style=\"float:right; padding-right:10px;\">&#128273;</span>";
		};
		resource_html := resource_html # "<p class=\"access_tag\">"# debug_show(r.access_type) # "</p>";
		
		return  resource_html # "</div>";	
	};	

	/**
	* Deploys new bucket canister and returns its id
	*/
	private func _register_bucket(repository:Types.Repository, operators : [Principal], name:Text, cycles : Nat): async Text {
		var access_tokens_opt:?[Types.AccessToken] = null;
		if (List.size(repository.access_keys) > 0) {
			let tokens = List.map(repository.access_keys, func (ac : Types.AccessKey):Types.AccessToken {
				{
					token = ICS2Utils.unwrap(ac.token);
					created = ac.created;
					valid_to = ac.valid_to;
				}
			});
			access_tokens_opt:=?List.toArray(tokens);
		};
		
		Cycles.add<system>(cycles);
		let bucket_actor = await ICS2DataBucket._DataBucket({
			// apply the user account as operator of the bucket
			name = name;
			operators = operators;
			network = initArgs.network;
			access_type = repository.access_type;
			access_token = access_tokens_opt;
		});

		// run timer : default period in seconds
		ignore await bucket_actor.apply_cleanup_period (3600);

		let bucket_principal = Principal.fromActor(bucket_actor);
		// IC Application is a controller of the bucket. but other users could be added here
		if (Array.size(initArgs.spawned_canister_controllers) > 0){
			ignore management_actor.update_settings({
				canister_id = bucket_principal;
				settings = { controllers = ? ICS2Utils.include(initArgs.spawned_canister_controllers, Principal.fromActor(this));};
			});
		};
		return Principal.toText(bucket_principal);
	};	

	system func preupgrade() { 
	};

	system func postupgrade() {
	};

	public query func get_version() : async Text {
		return Utils.VERSION;
	};
	
  	public shared func wallet_receive() {
    	let amount = Cycles.available();
    	ignore Cycles.accept<system>(amount);
  	};
	
	public query func available_cycles() : async Nat {
		return Cycles.balance();
  	};	
};
