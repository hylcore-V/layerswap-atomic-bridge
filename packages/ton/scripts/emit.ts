import { HttpClient, Api } from 'tonapi-sdk-js';
import { Cell } from '@ton/core';
import { Address } from 'ton';
import { hexToBase64 } from '../utils/utils';
import { loadCommitId } from '../wrappers/HashedTimeLockTON';

async function parseEmit(address: string, token: string, index: number) {
    const httpClient = new HttpClient({
        baseUrl: 'https://testnet.tonapi.io',
        baseApiParams: {
            headers: {
                Authorization: `Bearer ${token}`,
                'Content-type': 'application/json'
            }
        }
    });

    const client = new Api(httpClient);

    try {
        const tx = await client.blockchain.getBlockchainAccountTransactions(Address.parse(address).toString());
        for (let i = 0; i < tx.transactions[index].out_msgs.length; i++) {
            if (tx.transactions[index].out_msgs[i].msg_type === 'ext_out_msg' && tx.transactions[index].out_msgs[i].op_code === '0x2eec4b61' ) {
                let rawBody = tx.transactions[index].out_msgs[i].raw_body??"";
                let slc = Cell.fromBase64(hexToBase64(rawBody)).beginParse();
                return loadCommitId(slc)
            }
        }
    } catch (error) {
        console.error("Error fetching data from TON API:", error);
    }
}

const address = 'kQBZrfDyC4__ByU_1jL1APW_CtQZDrqk1QxAybM2mTMYFTsp'; 
const token = 'AGVYQVBYQDB6KRAAAAAFWAOS73LJHXPEWONMCFRIRGOBL7WIDI5D5G2GRWOD347TUUFWPUA'; 

parseEmit(address, token, 0)
    .then(result => console.log(result))
    .catch(error => console.error("Error processing request:", error));




