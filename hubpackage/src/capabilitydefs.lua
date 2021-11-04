local power_cap = [[
{
    "id": "partyvoice23922.rokupower",
    "version": 1,
    "status": "proposed",
    "name": "rokupower",
    "attributes": {
        "powerSwitch": {
            "schema": {
                "type": "object",
                "properties": {
                    "value": {
                        "type": "string",
                        "enum": [
                            "On",
                            "Off"
                        ]
                    }
                },
                "additionalProperties": false,
                "required": [
                    "value"
                ]
            },
            "enumCommands": []
        }
    },
    "commands": {
        "powerOn": {
            "name": "powerOn",
            "arguments": []
        },
        "powerOff": {
            "name": "powerOff",
            "arguments": []
        },
        "setPower": {
            "name": "setPower",
            "arguments": [
                {
                    "name": "state",
                    "optional": false,
                    "schema": {
                        "type": "string",
                        "enum": [
                            "On",
                            "Off"
                        ]
                    }
                }
            ]
        }
    }
}
]]


local mediastat_cap = [[
{
    "id": "partyvoice23922.rokumediastatus",
    "version": 1,
    "status": "proposed",
    "name": "rokumediastatus",
    "attributes": {
        "mediaStatus": {
            "schema": {
                "type": "object",
                "properties": {
                    "value": {
                        "type": "string"
                    }
                },
                "additionalProperties": false,
                "required": [
                    "value"
                ]
            },
            "enumCommands": []
        }
    },
    "commands": {}
}
]]


local currapp_cap = [[
{
    "id": "partyvoice23922.rokucurrentapp",
    "version": 1,
    "status": "proposed",
    "name": "rokucurrentapp",
    "attributes": {
        "currentApp": {
            "schema": {
                "type": "object",
                "properties": {
                    "value": {
                        "type": "string"
                    }
                },
                "additionalProperties": false,
                "required": [
                    "value"
                ]
            },
            "enumCommands": []
        }
    },
    "commands": {}
}
]]


local keypress_cap = [[
{
    "id": "partyvoice23922.rokukeys",
    "version": 1,
    "status": "proposed",
    "name": "rokukeys",
    "attributes": {
        "rokuKey": {
            "schema": {
                "type": "object",
                "properties": {
                    "value": {
                        "type": "string",
                        "maxLength": 20
                    }
                },
                "additionalProperties": false,
                "required": [
                    "value"
                ]
            },
            "setter": "selectKey",
            "enumCommands": []
        }
    },
    "commands": {
        "selectKey": {
            "name": "selectKey",
            "arguments": [
                {
                    "name": "value",
                    "optional": false,
                    "schema": {
                        "type": "string",
                        "maxLength": 20
                    }
                }
            ]
        }
    }
}
]]

local tvkeypress_cap = [[
{
    "id": "partyvoice23922.rokutvkeys",
    "version": 1,
    "status": "proposed",
    "name": "rokutvkeys",
    "attributes": {
        "rokuTVKey": {
            "schema": {
                "type": "object",
                "properties": {
                    "value": {
                        "type": "string",
                        "maxLength": 20
                    }
                },
                "additionalProperties": false,
                "required": [
                    "value"
                ]
            },
            "setter": "selectTVKey",
            "enumCommands": []
        }
    },
    "commands": {
        "selectTVKey": {
            "name": "selectTVKey",
            "arguments": [
                {
                    "name": "value",
                    "optional": false,
                    "schema": {
                        "type": "string",
                        "maxLength": 20
                    }
                }
            ]
        }
    }
}
]]

return {
	power_cap = power_cap,
	mediastat_cap = mediastat_cap,
	currapp_cap = currapp_cap,
	keypress_cap = keypress_cap,
    tvkeypress_cap = tvkeypress_cap,
}
