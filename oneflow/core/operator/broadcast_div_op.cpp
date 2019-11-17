#include "oneflow/core/operator/broadcast_binary_op.h"

namespace oneflow {

class BroadcastDivOp final : public BroadcastBinaryOp {
 public:
  OF_DISALLOW_COPY_AND_MOVE(BroadcastDivOp);
  BroadcastDivOp() = default;
  ~BroadcastDivOp() override = default;

 private:
  const PbMessage& GetCustomizedConf() const override;
  Maybe<void> VirtualGetSbpSignatures(
      const std::function<Maybe<const BlobDesc*>(const std::string&)>& LogicalBlobDesc4Ibn,
      SbpSignatureList* sbp_sig_list) const override;
};

const PbMessage& BroadcastDivOp::GetCustomizedConf() const {
  return op_conf().broadcast_div_conf();
}

Maybe<void> BroadcastDivOp::VirtualGetSbpSignatures(
    const std::function<Maybe<const BlobDesc*>(const std::string&)>& LogicalBlobDesc4Ibn,
    SbpSignatureList* sbp_sig_list) const {
  SbpSignatureBuilder().PartialSum("a").Broadcast("b").PartialSum("out").Build(
      sbp_sig_list->mutable_sbp_signature()->Add());
  return Maybe<void>::Ok();
}

REGISTER_OP(OperatorConf::kBroadcastDivConf, BroadcastDivOp);

}  // namespace oneflow
