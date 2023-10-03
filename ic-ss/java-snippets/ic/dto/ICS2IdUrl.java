package ic.dto;

import org.ic4j.candid.annotations.Field;
import org.ic4j.candid.annotations.Name;
import org.ic4j.candid.types.Type;

public class ICS2IdUrl {
	
	@Field(Type.TEXT)
	@Name("id")
	public String id;

	@Field(Type.TEXT)
	@Name("url")
	public String url;

	@Field(Type.TEXT)
	@Name("partition")
	public String partition;
}
