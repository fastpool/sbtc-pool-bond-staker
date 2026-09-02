# Shared dependency wiring for verifying bond-staker.
# Order matters: each contract is instantiated before the ones that call it.
export DEPLOYER=SP000000000000000000002Q6VF78
export CLV=~/_repos/github/jcnelson/clairvoyance/target/debug/clairvoyance
DEPS=(
  --dep SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token:verification/sbtc-token.clar
  --dep ST000000000000000000002AMW42H.pox-5:verification/pox-5.clar
  --dep $DEPLOYER.bond-escrow:verification/bond-escrow.clar
  --dep SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-withdrawal:verification/sbtc-withdrawal.clar
  --dep $DEPLOYER.bond-treasury:contracts/bond-treasury.clar
  --dep $DEPLOYER.signer-manager:verification/signer-manager.clar
)
