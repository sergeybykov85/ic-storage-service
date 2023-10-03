package ic.dto;

import java.io.Serializable;

import org.apache.commons.lang3.StringUtils;

import com.fasterxml.jackson.annotation.JsonInclude;

import io.swagger.annotations.ApiModel;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@ApiModel("ICS2InputDto")
@JsonInclude(JsonInclude.Include.NON_NULL)
@NoArgsConstructor
public class ICS2InputDto implements Serializable {
	private static final long serialVersionUID = -752277415645333341L;
	private String name;
	private String value;
	private String reference;
	private String contentType;
	private String parentPath;

	public ICS2InputDto(String name, String value) {
		this();
		this.name = name;
		this.value = value;
		this.reference = null;
	}

	public boolean setByReference() {
		return StringUtils.isNotBlank(reference);
	}
	
	public static ICS2InputDto ofReference(String name, String reference) {
		return ofReference(name, reference, null);
	}
	
	public static ICS2InputDto ofReference(String name, String reference, String contentType) {
		ICS2InputDto r = new ICS2InputDto(name, null);
		r.setReference(reference);
		r.setContentType(contentType);
		return r;
	}	

}
