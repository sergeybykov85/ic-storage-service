package ic.dto;

import org.ic4j.candid.annotations.Field;
import org.ic4j.candid.annotations.Name;
import org.ic4j.candid.types.Type;

public enum ICS2TextResult {
	ok,

	err;

	@Name("ok")
	@Field(Type.RECORD)
	public String okValue;

	@Name("err")
	@Field(Type.VARIANT)
	public ICS2Errors errValue;
}
