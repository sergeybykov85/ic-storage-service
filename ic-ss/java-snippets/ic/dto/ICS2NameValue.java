package ic.dto;

import org.ic4j.candid.annotations.Field;
import org.ic4j.candid.annotations.Name;
import org.ic4j.candid.types.Type;

public class ICS2NameValue {
	
	@Field(Type.TEXT)
	@Name("name")
	public String name;
	
	@Field(Type.TEXT)
	@Name("value")
	public String value;	
}
