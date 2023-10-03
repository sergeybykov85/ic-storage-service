package ic.dto;

import java.io.Serializable;

import com.fasterxml.jackson.annotation.JsonInclude;

import io.swagger.annotations.ApiModel;
import lombok.Data;
import lombok.NoArgsConstructor;

@Data
@ApiModel("ICS2ActionResourceDto")
@JsonInclude(JsonInclude.Include.NON_NULL)
@NoArgsConstructor
public class ICS2ActionResourceDto implements Serializable {
	private static final long serialVersionUID = -752277415645333341L;
	private String id;
	private String partition;
	private String repository;
	/**
	 * Other parameter could be added to send more operations into ICS2
	 */

	public ICS2ActionResourceDto(String id, String partition) {
		this();
		this.id = id;
		this.partition = partition;
	}

}
