# S3 バケット暗号化 / パブリックアクセスブロック必須（#296 の見送り初期候補）。ADR-0017の
# 再検討トリガー「#280が完了したら追加する」に対応 -- #280はCMK導入を見送ってSSE-S3のまま
# 確定し（#591 でこの構成のCloudFront OAC非互換を実機修正）、app層のweb.tfは既に両方の
# リソースを持つため、今この検証を追加しても現状の構成には違反しない。
#
# aws_s3_bucket_server_side_encryption_configuration / aws_s3_bucket_public_access_block
# の `bucket` 属性値では突き合わせない -- 同一plan内でバケットと一緒に新規作成される場合、
# その値はapply後にしか定まらない(unknown)ため。代わりにこのテンプレートの命名規約
# （aws_s3_bucket.web + aws_s3_bucket_server_side_encryption_configuration.web のように
# 保護対象と同じローカル名を使う）でリソースアドレスを突き合わせる。
package main

local_name(address) := split(address, ".")[1]

s3_buckets contains rc if {
	rc := input.resource_changes[_]
	rc.type == "aws_s3_bucket"
	rc.change.after != null
}

has_encryption(name) if {
	rc := input.resource_changes[_]
	rc.type == "aws_s3_bucket_server_side_encryption_configuration"
	local_name(rc.address) == name
	rc.change.after != null
}

has_public_access_block(name) if {
	rc := input.resource_changes[_]
	rc.type == "aws_s3_bucket_public_access_block"
	local_name(rc.address) == name
	after := rc.change.after
	after != null
	after.block_public_acls == true
	after.block_public_policy == true
	after.ignore_public_acls == true
	after.restrict_public_buckets == true
}

deny contains msg if {
	bucket := s3_buckets[_]
	name := local_name(bucket.address)
	not has_encryption(name)
	msg := sprintf("%s has no aws_s3_bucket_server_side_encryption_configuration (matched by resource name %q)", [bucket.address, name])
}

deny contains msg if {
	bucket := s3_buckets[_]
	name := local_name(bucket.address)
	not has_public_access_block(name)
	msg := sprintf("%s has no aws_s3_bucket_public_access_block blocking all public access (matched by resource name %q)", [bucket.address, name])
}
