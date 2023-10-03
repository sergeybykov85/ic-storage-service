package ic.dto;

public enum ICS2Errors {
	// the tier is not confifured or absent
    TierNotFound,
	// Tier restriction
    TierRestriction,		
	// no resource or no chunk
	NotFound,
	// record already registered
	DuplicateRecord,
	// action not allowed by the logic or constraints
    OperationNotAllowed,
    // not registered
    NotRegistered,
	// when input argument contains wrong value
	InvalidRequest,
    // exceeded allowed items
    ExceededAllowedLimit,	
	// not authorized to manage certain object
	AccessDenied;	
}
