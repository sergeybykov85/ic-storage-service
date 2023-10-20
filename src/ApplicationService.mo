import Cycles "mo:base/ExperimentalCycles";
import Array "mo:base/Array";
import List "mo:base/List";
import Buffer "mo:base/Buffer";
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

import Application "Application";
import Types "./Types";
import Utils "./Utils";

shared (installation) actor class ApplicationService(initArgs : Types.ApplicationServiceArgs) = this {

	// owner has a super power, do anything inside this actor and assign any list of operators
    stable let OWNER = installation.caller;

	let TIER_ON_SIGNUP : Types.TierId = #Free;

	// operator has enough power, but can't apply a new operator list or change the owner, etc
	stable var operators = initArgs.operators;

	// list of customers who can sign up and get a "free tier";
	stable var whitelist_customers : [Principal] = [];

	stable var applications : Trie.Trie<Principal, Types.CustomerApp> = Trie.empty();

	stable var customers : Trie.Trie<Principal, Types.Customer> = Trie.empty();

	stable var configuration_service =  Option.get(initArgs.configuration_service, "");

	let management_actor : Types.ICManagementActor = actor "aaaaa-aa";

	public shared query func initParams() : async (Types.ApplicationServiceArgs) {
		return initArgs;
	};

	/**
	* Applies the list of operators for the storage service.
	* Allowed only to the owner user
	*/
    public shared ({ caller }) func apply_operators(ids: [Principal]) {
		assert(caller == OWNER);
    	operators := ids;
    };

	/**
	* Applies (override) the list of customers who can sign up and get a free tier access immediately. 
	* Allowed only to the owner user or operator.
	*/
    public shared ({caller}) func apply_whitelist_customers(ids: [Principal]) {
		assert(caller == OWNER or _is_operator(caller));
    	whitelist_customers := ids;
    };

	/**
	* Adds the list of customers who can sign up and get a free tier access immediately. The previous list remains availaible.
	* Allowed only to the owner user or operator.
	*/
    public shared ({ caller }) func add_whitelist_customers(ids: [Principal]) {
    	assert(caller == OWNER or _is_operator(caller));
    	whitelist_customers := Utils.join(whitelist_customers, ids);
    };	

	public query func access_list() : async (Types.AccessList) {
		return { owner = OWNER; operators = operators }
	};

	/**
	* Applies a new tier options for the existing customer and all its created applications.
	* Allowed only to the owner user or operator.
	*/
	public shared ({caller}) func migrate_customer_tier (identity : Principal, tier : Types.Tier): async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (customer_get(identity)) {
			case (?customer) {
				customer.tier := tier;
				for (a_id in List.toIter(customer.applications)) {
					let app_actor : Types.ApplicationActor = actor (a_id);
					await app_actor.apply_tier(tier);
				};
			};
			case (null) { return #err(#NotFound);};
		};
		return #ok();
	};

	/**
	* Updates the existing customer : name,description
	* Allowed only to the owner user or operator.
	*/
	public shared ({caller}) func update_customer (args : Types.CommonUpdateArgs): async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		let identity = Principal.fromText(args.id);
		switch (customer_get(identity)) {
			case (?customer) {
				if (Option.isSome(args.name)) {
					customer.name:= Utils.unwrap(args.name);
				};
				if (Option.isSome(args.description)) {
					customer.description:= Utils.unwrap(args.description);
				};				
			};
			case (null) { return #err(#NotFound);};
		};
		return #ok();
	};
	/**
	* Updates an existing app.
	* Allowed only to the application owner.
	*/
	public shared ({caller}) func update_my_application (args : Types.CommonUpdateArgs): async Result.Result<(), Types.Errors> {
		let identity = Principal.fromText(args.id);
		switch (application_get(identity)) {
			case (?application) {
				// access control : application owner
				if (application.owner != caller) return #err(#AccessDenied);				
				if (Option.isSome(args.name)) {
					application.name:= Utils.unwrap(args.name);
				};
				if (Option.isSome(args.description)) {
					application.description:= Utils.unwrap(args.description);
				};				
			};
			case (null) { return #err(#NotFound);};
		};
		return #ok();
	};

	public shared ({caller}) func get_my_customer (): async Result.Result<Types.CustomerView, Types.Errors> {
		switch (customer_get(caller)) {
			case (?customer) { return #ok(Utils.customer_view(customer)); };
			case (null) { return #err(#NotFound);};
		};
	};

		/**
	* Updates the existing customer : name,description
	* Allowed only to the owner user or operator.
	*/
	public shared ({caller}) func update_my_customer (name:Text, description:Text): async Result.Result<(), Types.Errors> {
		switch (customer_get(caller)) {
			case (?customer) {
				customer.name:= name;
				customer.description:= description;
			};
			case (null) { return #err(#NotFound);};
		};
		return #ok();
	};

	/**
	* Registers a new customer.
	* Allowed only to the owner or operator of the storage service.
	*/
	public shared ({ caller }) func register_customer (name : Text, description : Text, identity : Principal, tier_id : Types.TierId) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);

		switch (customer_get(identity)) {
			case (?customer) {
				return #err(#DuplicateRecord);
			};
			case (null) {
				let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
				let settings = switch(await configuration_actor.get_tier_options(tier_id)){
					case (#ok(t)) {t;};
					case (#err(t)) { return #err(t); };
				};

				let customer : Types.Customer = {
					var name = name;
					var description = description;			
					identity = identity;
					var tier = {
						id = tier_id;
						options = settings;
					};
					var applications = List.nil();
					created = Time.now();
				};
				customers := Trie.put(customers, Utils.principal_key(identity), Principal.equal, customer).0;
				return #ok(Principal.toText(identity));
			};
		}
	};

	/**
	* Sign up as a new customer. Allowed only if a caller belongs to the whitelist. 
	* A new customer receives a "Free tier".
	*/
	public shared ({ caller }) func signup_customer (name : Text, description : Text) : async Result.Result<Text, Types.Errors> {
		if (Option.isSome(Array.find(whitelist_customers, func (x: Principal) : Bool { x == caller }))) {

			switch (customer_get(caller)) {
				case (?customer) { return #err(#DuplicateRecord); };
				case (null) {
					let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
					let settings = switch(await configuration_actor.get_tier_options(TIER_ON_SIGNUP)){
						case (#ok(t)) {t;};
						case (#err(t)) { return #err(t); };
					};					
					// register customer with a Free tier
					let customer : Types.Customer = {
						var name = name;
						var description = description;			
						identity = caller;
						var tier = {
							id = TIER_ON_SIGNUP;
							options = settings;
						};
						var applications = List.nil();
						created = Time.now();
					};
					customers := Trie.put(customers, Utils.principal_key(caller), Principal.equal, customer).0;
					return #ok(Principal.toText(caller));
				};
			};
		} else {
			return #err(#AccessDenied);
		}
	};	


	/**
	* Registers a new application for already registered customer. Customer should call this method to register an app.
	* The idea is so that caller is a customer.
	*/
	public shared ({ caller }) func register_application (name : Text, description : Text) : async Result.Result<Text, Types.Errors> {
		// if caller is not a customer then method returns #err(NotRegistered)
		await _register_application(name, description, caller, null);
	};

	/**
	* Deletes the existing application
	* Allowed only to the owner of the certain application
	*/
	public shared ({ caller }) func delete_application (id : Text) : async Result.Result<Text, Types.Errors> {
		// only application owner can delete its app
		let app_principal = Principal.fromText(id);
		switch (application_get(app_principal)) {
			case (?app) {
				// access control : application owner
				if (app.owner != caller) return #err(#AccessDenied);
				let ic_storage_wallet : Types.Wallet = actor (id);

				let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
				let remainder_cycles = await configuration_actor.get_remainder_cycles();
				/**
				*  send cycles to "application service canister" in case of removing a application canister.
				*  right now, remainder_cycles is a constant, the idea is to leave some funds to process the request
				*/
				await ic_storage_wallet.withdraw_cycles({to = Principal.fromActor(this); remainder_cycles = ?remainder_cycles});

				await management_actor.stop_canister({canister_id = app_principal});
				await management_actor.delete_canister({canister_id = app_principal});
				applications := Trie.remove(applications, Utils.principal_key(app_principal), Principal.equal).0;
				#ok(id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};	

	private func _register_application (name : Text, description : Text, to : Principal, cycles : ?Nat) : async Result.Result<Text, Types.Errors> {
		switch (customer_get(to))	{
			case (?customer) {
				if (List.size(customer.applications) >= customer.tier.options.number_of_applications) return #err(#TierRestriction);

				let cycles_assign = switch (cycles) {
					case (?c) {c;};
					case (null) { 
						let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
						await configuration_actor.get_app_init_cycles(); 
					};
				};
				Cycles.add(cycles_assign);
				let application_actor = await Application.Application({
					tier = customer.tier;
					configuration_service = configuration_service;
					operators = [Principal.fromActor(this), to];
					// owner of the application service is a controller for any "spawned" canisters!
					spawned_canister_controllers = initArgs.spawned_canister_controllers;
					network = initArgs.network;
				});
				
				let application_principal = Principal.fromActor(application_actor);

				// IC ApplicationService is a controller of the application. but other users could be added here
				if (Array.size(initArgs.spawned_canister_controllers) > 0){
					ignore management_actor.update_settings({
						canister_id = application_principal;
						settings = { controllers = ? Utils.include(initArgs.spawned_canister_controllers, Principal.fromActor(this));};
					});
				};

				let app_id = Principal.toText(application_principal);
				let app : Types.CustomerApp = {
					var name = name;
					var description = description;			
					owner = to;
					created = Time.now();
				};
				applications := Trie.put(applications, Utils.principal_key(application_principal), Principal.equal, app).0;
				customer.applications := List.push(app_id, customer.applications);

				return #ok(app_id);
			};
			case (null) {
				// customer is not registered
				return #err(#NotRegistered);
			};
		}
	};

	/**
	* Checks if entity belongs to the whitelist set
	*/	
	public query func is_in_whitelist(id: Principal) : async Bool {
    	Option.isSome(Array.find(whitelist_customers, func (x: Principal) : Bool { x == id }))
    };	

	public query func total_customers() : async Nat {
		return Trie.size(customers);
	};

	public query func total_apps() : async Nat {
		return Trie.size(applications);
	};

	public query func get_whitelist_customer_records() : async [Principal] {
		return whitelist_customers
	};	

	/**
	* Returns customer apps for the specified customer.
	*/	
	public shared ({ caller }) func get_application_records_for(customer : Principal) : async [Types.CustomerAppView] {
		assert(caller == OWNER or _is_operator(caller));
		_get_application_records_for(customer);
  	};

	/**
	* Returns customers for the specified tier
	*/	
	public shared ({ caller }) func get_customers_for_tier(tier_id : Types.TierId) : async [Types.CustomerView] {
		assert(caller == OWNER or _is_operator(caller));
		_get_customers_for_tier(tier_id);
  	};	

	/**
	* Returns customer apps for the current user.
	*/	
	public shared ({ caller }) func get_my_application_records() : async [Types.CustomerAppView] {
		_get_application_records_for(caller);
  	};

	private func _get_application_records_for(customer : Principal) : [Types.CustomerAppView] {
    	switch (customer_get(customer)) {
        	case (?c) {
				let res = Buffer.Buffer<Types.CustomerAppView>(List.size(c.applications));

				for (app_id in List.toIter(c.applications)) {
					let app_principal = Principal.fromText(app_id);
					switch (application_get(app_principal)){
						case (?app) res.add(Utils.customerApp_view(app_principal, app));
						case (null) {
							// nothing
						};
					}
				};
				Buffer.toArray(res);
        	};
        	case (_) {[];};
      	};
  	};

	private func _get_customers_for_tier(tier_id : Types.TierId) : [Types.CustomerView] {
		let res = Buffer.Buffer<Types.CustomerView>(Trie.size(customers));
		for ((p, c) in Trie.iter(customers)){
			if (c.tier.id == tier_id) {
				res.add(Utils.customer_view(c));
			}
		};
		return Buffer.toArray(res);
  	};	

    private func customer_get(id : Principal) : ?Types.Customer = Trie.get(customers, Utils.principal_key(id), Principal.equal);
    
	private func application_get(id : Principal) : ?Types.CustomerApp = Trie.get(applications, Utils.principal_key(id), Principal.equal);

	private func _is_operator(id: Principal) : Bool {
    	Option.isSome(Array.find(operators, func (x: Principal) : Bool { x == id }))
    };

	/**
	* Returns all registered customer apps.
	*/	
	public shared ({ caller }) func get_application_records() : async [Types.CustomerAppView] {
		assert(caller == OWNER or _is_operator(caller));
		return Iter.toArray(Iter.map (Trie.iter(applications), 
			func (i: (Principal, Types.CustomerApp)): Types.CustomerAppView {Utils.customerApp_view(i.0, i.1)}));
	};

	/**
	* Returns all registered customers.
	*/
	public shared ({ caller }) func get_customer_records() : async [Types.CustomerView] {
		assert(caller == OWNER or _is_operator(caller));
		return Iter.toArray(Iter.map (Trie.iter(customers), 
			func (i: (Principal, Types.Customer)): Types.CustomerView {Utils.customer_view(i.1)}));
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
