import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import List "mo:base/List";

module {

	public type AccessList = {owner : Principal; operators : [Principal]};

	public type NameValue = {
		name : Text;
		value : Text;
	};
	
	public type Wallet = actor {
    	wallet_receive : () -> async ();
    };

	// state of the bucket or repository itself
	public type PartitionStatus = {
		cycles : Int;
		memory_mb : Int;
		heap_mb : Int;
		files : Nat;
		directories : Nat;
	};

	public type ApprovedCustomer = {
		// some status could be added here later
		identity : Principal;
		created: Time.Time;
	};

	public type Customer = {
		var name : Text;
		var description : Text;
		identity : Principal;
		tier : ServiceTier;
		// principal id
		var applications : List.List<Text>;
		created: Time.Time;
	};

	public type CustomerView = {
		name : Text;
		description : Text;
		identity : Principal;
		tier : ServiceTier;
		applications : [Text];
		created: Time.Time;
	};	

	public type CustomerApp = {
		var name : Text;
		var description : Text;
		owner : Principal;
		created : Time.Time;
	};

	public type CustomerAppView = {
		id : Principal;
		name : Text;
		description : Text;
		owner : Principal;
		created : Time.Time;
	};	

	public type Repository = {
		var name : Text;
		var description : Text;
		var buckets : List.List<Text>;
		var active_bucket : Text;
		created : Time.Time;
	};

	public type RepositoryView = {
		id : Text;
		name : Text;
		description : Text;
		buckets : [Text];
		active_bucket : Text;
		created : Time.Time;
	};	

	/**
	* Trier represents the list of opportunities.
	* In the first version there is no difference. But limits will be applied based on the tier.
	* (number of apps, number of repos, buckets etc)
	*/
	public type ServiceTier = {
		#Free;
		#Standard;
		#Advanced;
	};

	public type Network = {
        #IC;
        #Local: Text; // host details like localhost:4943
    };

	public type ViewMode = {
		#Names;     // names could be used as a part of browser url
		#Open;      // references to the resource by its hash
		#Download;  // reference to the resource by its hash, download in browser
	};

	public type ResourceType = {
		#File;
		#Directory;
	};

	public type ChunkBinding = {
		var chunks : List.List<Text>;
		created : Time.Time;
	};

	public type ResourceChunk = {
		content : Blob;
		created : Time.Time;
		id : Text;
		// opportunity to link chunks by a logical name
		binding_key : ?Text;
	};
	// Type object to create a new resource
	public type ResourceArgs = {
		content_type : ?Text;
		name : Text;
		// input argument, directory name
		directory : ?Text;
	};

	public type ResourceAction = {
		#Copy;
		#Delete;
		#Rename;
	};
	// Type contains possible required data to make some action with an existing resource
	public type ActionResourceArgs = {
		id : Text;
		action : ResourceAction;
		name : ?Text;
		directory : ?Text;
	};	

	public type Resource = {
		resource_type : ResourceType;
		var http_headers : [(Text, Text)];
		content_size : Nat;
		created : Int;
		var name : Text;
		// folder reference (hash, not the name)
		var parent : ?Text;
		// references to other resources in case of "folder type"
		var leafs : List.List<Text>;
		// data identifier 
		did : ?Text;		
	};

	public type ResourceView = {
		id : Text;
		resource_type : ResourceType;
		content_size : Nat;
		created : Int;
		name : Text;
		url : Text;
	};

	public type IdUrl = {
		id : Text;
		url : Text;
	};

	public type DirectoryView = {
		id : Text;
		total_files : Nat;
		total_size : Nat;
		created : Int;
		url : Text;
	};		

	public type ApplicationServiceArgs = {
		// network that propagated to any application
		network : Network;
		// list of operators to work with the service
		operators : [Principal];
		// default cycles sent to any new application
		cycles_app_init : ?Nat;
		// default cycles sent to a new bucket (application --> repo)
		cycles_bucket_init : ?Nat;
	};

	public type ApplicationArgs = {
		network : Network;
		// tier or the opportunitites
		tier : ServiceTier;
		// operators to work with a repo
		operators : [Principal];
		// initial amount of cycles for any new bucket
		cycles_bucket_init : Nat;
	};	

	public type BucketArgs = {
		name : Text;
		network : Network;
		operators : [Principal];
	};

	public type CommitArgs = {
		chunks : [Text];
		binding_key: ?Text;
	};

	public type WitdrawArgs = {
		to : Principal;
		// cycles to leave before making the withdraw request
		remainder_cycles :?Nat;
	};

	public type Errors = {
		// not authorized
        #NotAuthorized;
		// no resource or no chunk
		#NotFound;
		// record already registered
		#DuplicateRecord;
		// action not allowed by the logic or constraints
        #OperationNotAllowed;
        // not registered
        #NotRegistered;
        // exceeded allowed items
        #ExceededAllowedLimit;	
		// not authorized to manage certain object
		#AccessDenied;	
    };

    public type ICSettingsArgs = {
        controllers : ?[Principal];
        freezing_threshold : ?Nat;
        memory_allocation : ?Nat;
        compute_allocation : ?Nat;
    };	

    public type ICManagementActor = actor {
        stop_canister : shared { canister_id : Principal } -> async ();
		delete_canister : shared { canister_id : Principal } -> async ();
        update_settings : shared {
            canister_id : Principal;
            settings : ICSettingsArgs;
        } -> async ();
    };

    public type DataBucketActor = actor {
        withdraw_cycles : shared {to : Principal; remainder_cycles : ?Nat} -> async ();
		new_directory : shared (name : Text, parent_path:?Text) -> async Result.Result<IdUrl, Errors>;
        get_status : shared query () -> async PartitionStatus;		
		execute_action : shared (args : ActionResourceArgs) -> async Result.Result<(), Errors>;
		store_resource : shared (content : Blob, resource_args : ResourceArgs ) -> async Result.Result<IdUrl, Errors>;
		store_chunk : shared (content : Blob, binding_key : ?Text ) -> async Result.Result<Text, Errors>;
		commit_batch : shared (chunk_ids : [Text], resource_args : ResourceArgs ) -> async Result.Result<IdUrl, Errors>;
		commit_batch_by_key : shared (binding_key:Text, resource_args : ResourceArgs ) -> async Result.Result<IdUrl, Errors>;
	};			

};
