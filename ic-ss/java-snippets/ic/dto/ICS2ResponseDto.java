package ic.dto;

import java.io.Serializable;

import com.fasterxml.jackson.annotation.JsonInclude;

import io.swagger.annotations.ApiModel;
import lombok.Data;

@Data
@ApiModel("ICS2ResponseDto")
@JsonInclude(JsonInclude.Include.NON_NULL)
public class ICS2ResponseDto implements Serializable {

	private static final long serialVersionUID = -7243075389948020823L;

	private String error;
	
	private String repository;

	private String id;

	private String url;

	private String partition;
}
