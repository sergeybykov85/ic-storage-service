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
		resources : Nat;
		folders : Nat;
	};

	public type Customer = {
		var name : Text;
		var description : Text;
		identity : Principal;
		// principal id
		var applications : List.List<Text>;
		created: Time.Time;
	};

	public type CustomerView = {
		name : Text;
		description : Text;
		identity : Principal;
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
		#Folder;
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
		owner : Principal;
	};

	public type ResourceArgs = {
		content_type : Text;
		name : Text;
		// input argument, folder name
		folder : ?Text;
	};

	public type Resource = {
		resource_type : ResourceType;
		http_headers : [(Text, Text)];
		content_size : Nat;
		created : Int;
		name : Text;
		owner : Principal;
		// folder reference (hash, not the name)
		parent : ?Text;
		// references to other resources in case of "folder type"
		var leafs : List.List<Text>;		
	};

	public type ResourceView = {
		id : Text;
		resource_type : ResourceType;
		content_size : Nat;
		created : Int;
		name : Text;
		owner : Principal;
		url : Text;
	};

	public type IdUrl = {
		id : Text;
		url : Text;
	};

	public type FolderView = {
		id : Text;
		total_files : Nat;
		total_size : Nat;
		created : Int;
		url : Text;
	};		

	public type ApplicationServiceArgs = {
		network : Network;
		owner : Principal;
		operators : [Principal];
		cycles_app_init : Nat;
		cycles_bucket_init : Nat;
	};

	public type ApplicationArgs = {
		network : Network;
		// operators to work with a repo
		operators : [Principal];
		// max allowed repos per application
		allowed_repositories : Nat;
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
		#AlreadyRegistered;
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
		new_folder : shared (name : Text) -> async Result.Result<IdUrl, Errors>;
        get_status : shared query () -> async PartitionStatus;		
		store_resource : shared (content : Blob, resource_args : ResourceArgs ) -> async Result.Result<IdUrl, Errors>;
    };			

};
