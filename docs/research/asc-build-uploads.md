# App Store Connect Build Uploads API (verified)

Source: Apple's official OpenAPI spec (App Store Connect API 4.5.1),
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
(`openapi.oas.json`, downloaded 2026-10-13, parsed as data).

## Paths
- `POST /v1/buildUploads`
- `GET|DELETE /v1/buildUploads/{id}` (params: `include` in [build, assetFile, assetDescriptionFile, assetSpiFile], `fields[buildUploads]`, `fields[builds]`, `fields[buildUploadFiles]`)
- `POST /v1/buildUploadFiles`
- `GET|PATCH /v1/buildUploadFiles/{id}`
- `GET /v1/buildUploads/{id}/buildUploadFiles`, `GET /v1/apps/{id}/buildUploads`
- `GET /v1/builds/{id}`
- There is NO `GET /v1/buildUploads/{id}/build` path. The build is reached via the `build` relationship of the BuildUpload (use `?include=build`, or read `relationships.build.data.id`) and then `GET /v1/builds/{id}`.

## BuildUploadCreateRequest
`data { type: "buildUploads", attributes { cfBundleShortVersionString*, cfBundleVersion*, platform* }, relationships { app* { data { type: "apps", id } } } }`
- `platform` (schema `Platform`): `IOS | MAC_OS | TV_OS | VISION_OS`

## BuildUploadFileCreateRequest
`data { type: "buildUploadFiles", attributes { assetType*, fileName*, fileSize* (int >= 1), uti* }, relationships { buildUpload* { data { type: "buildUploads", id } } } }`
- `assetType`: `ASSET | ASSET_DESCRIPTION | ASSET_SPI`
- `uti`: `com.apple.binary-property-list | com.apple.ipa | com.apple.pkg | com.apple.xml-property-list | com.pkware.zip-archive`

## BuildUploadFile (response)
attributes: `assetDeliveryState {errors[], warnings[], state: AWAITING_UPLOAD|UPLOAD_COMPLETE|COMPLETE|FAILED}`, `assetToken`, `assetType`, `fileName`, `fileSize`, `sourceFileChecksums`, `uploadOperations[]`, `uti`.
`uploadOperations[]` (DeliveryFileUploadOperation): `method`, `url`, `length`, `offset`, `requestHeaders[{name,value}]`, `expiration`, `partNumber`, `entityTag`.

## BuildUploadFileUpdateRequest
`data { type: "buildUploadFiles", id, attributes { sourceFileChecksums? { file { hash, algorithm }, composite { hash, algorithm: MD5 } }, uploaded? (bool) } }`
- `ChecksumAlgorithm` (for `file`): `MD5 | SHA_256`

## BuildUpload (response)
attributes: `cfBundleShortVersionString`, `cfBundleVersion`, `createdDate`, `platform`, `uploadedDate`,
`state { state: AWAITING_UPLOAD|PROCESSING|FAILED|COMPLETE, errors[StateDetail], warnings[StateDetail], infos[StateDetail] }`
- `StateDetail`: `{ code, description }`
relationships: `build { data {type: "builds", id} }`, `assetFile`, `assetDescriptionFile`, `assetSpiFile`, `buildUploadFiles`.

## Build.processingState
`PROCESSING | FAILED | INVALID | VALID`

## Differences from the plan's assumptions
Only one: no `/v1/buildUploads/{id}/build` endpoint. xless polls `GET /v1/buildUploads/{id}?include=build` for the build id, then `GET /v1/builds/{id}` for `processingState`. All attribute names, enums and the PATCH shape matched.

## Bundle ID registration platform (checked 2026-10-14)
Source: Apple's App Store Connect OpenAPI specification zip (`openapi.oas.json`, `info.version` 4.5.1), downloaded 2026-10-14 from developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip.
- `BundleIdPlatform` enum: `IOS | MAC_OS | UNIVERSAL`.
- `BundleIdCreateRequest.data.attributes`: `identifier`, `name`, `platform` (all required), `seedId` (optional).
- xless registers new bundle IDs as `UNIVERSAL`, so one identifier can carry both the iOS (`IOS_APP_STORE`) and the macOS (`MAC_APP_DIRECT`) profile. An identifier that already exists is reused as is; one registered earlier as `IOS` may refuse a macOS profile, in which case set `platforms.macos.bundleID` to a separate identifier.
- Confirmed against the live API (2026-10-14): the create call accepts `UNIVERSAL`, and both `IOS_APP_STORE` and `MAC_APP_DIRECT` profiles can be created for a `UNIVERSAL` identifier.
- The `name` attribute must contain only letters, digits and spaces; xless derives it from the identifier.
