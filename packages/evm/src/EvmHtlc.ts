import { AbiItem } from 'web3-utils';
import HashedTimelockEther from './abi/HashedTimelockEther.json';
import { BaseHTLCService } from './models/BaseHtlc';
import { LockOptions } from './models/Core';
import { HTLCBatchRedeemResult, HTLCMintResult, HTLCWithdrawResult } from './models/Contract';

/**
 * HTLC operations on the Ethereum Test Net.
 * Passing a value to the constructor will overwrite the specified value.
 */
export class EvmHtlc extends BaseHTLCService {
  constructor(providerEndpoint: string, contractAddress: string) {
    super(providerEndpoint, contractAddress, HashedTimelockEther.abi as unknown as AbiItem);
  }

  /**
   * Issue HTLC and obtain the key at the time of issue
   */
  public async lock(
    recipientAddress: string,
    senderAddress: string,
    secret: string,
    amount: number,
    chainId: number,
    receiverChainAddress: string,
    options?: LockOptions
  ): Promise<HTLCMintResult> {
    const value = this.web3.utils.toWei(this.web3.utils.toBN(amount), 'finney');
    const lockSeconds = options?.lockSeconds || 3600;
    const lockPeriod = Math.floor(Date.now() / 1000) + lockSeconds;

    const estimatedGas =
      options?.gasLimit ??
      Math.floor(
        (await this.estimateGas(
          { from: senderAddress, value },
          'createHTLC',
          recipientAddress,
          secret,
          lockPeriod,
          chainId,
          receiverChainAddress
        )) * 1.2
      );

    return await this.contract.methods
      .createHTLC(recipientAddress, secret, lockPeriod, chainId, receiverChainAddress)
      .send({ from: senderAddress, gas: estimatedGas.toString(), value });
  }

  /**
   * Receive tokens stored under the key at the time of HTLC generation
   */
  public async withdraw(
    contractId: string,
    senderAddress: string,
    proof: string,
    gasLimit?: number
  ): Promise<HTLCWithdrawResult> {
    const estimatedGas =
      gasLimit ?? Math.floor((await this.estimateGas({ from: senderAddress }, 'redeem', contractId, proof)) * 1.2);

    const result = await this.contract.methods
      .redeem(contractId, proof)
      .send({ from: senderAddress, gas: estimatedGas.toString() });

    return result as HTLCWithdrawResult;
  }

  /**
   * Withdraw multiple HTLCs in a batch using their contract IDs and corresponding secrets.
   */
  public async batchWithdraw(
    senderAddress: string,
    contractIds: string[],
    secrets: string[],
    gasLimit?: number
  ): Promise<HTLCBatchRedeemResult> {
    const estimateGasLimit =
      gasLimit ?? (await this.estimateGas({ from: senderAddress }, 'batchRedeem', contractIds, secrets));

    const result = await this.contract.methods
      .batchRedeem(contractIds, secrets)
      .send({ from: senderAddress, gas: estimateGasLimit.toString() });

    return result as HTLCBatchRedeemResult;
  }
}
