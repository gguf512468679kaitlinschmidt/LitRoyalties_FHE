// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract LitRoyalties_FHE is SepoliaConfig {
    struct EncryptedContribution {
        uint256 contributorId;
        euint32 encryptedStyleWeight;   // Encrypted style influence weight
        euint32 encryptedContentWeight; // Encrypted content influence weight
        euint32 encryptedUsageCount;    // Encrypted model usage count
        uint256 timestamp;
    }
    
    struct DecryptedContribution {
        float styleWeight;
        float contentWeight;
        uint256 usageCount;
        bool isRevealed;
    }

    uint256 public contributorCount;
    mapping(uint256 => EncryptedContribution) public encryptedContributions;
    mapping(uint256 => DecryptedContribution) public decryptedContributions;
    
    mapping(uint256 => euint32) private encryptedRoyaltyBalances;
    euint32 private totalRoyaltyPool;
    
    mapping(uint256 => uint256) private requestToContributionId;
    
    event ContributionAdded(uint256 indexed contributorId, uint256 timestamp);
    event RoyaltyDistributed(uint256 indexed distributionId);
    event ContributionDecrypted(uint256 indexed contributionId);
    event RoyaltyWithdrawn(uint256 indexed contributorId);
    
    modifier onlyContributor(uint256 contributorId) {
        _;
    }
    
    function registerEncryptedContribution(
        euint32 encryptedStyleWeight,
        euint32 encryptedContentWeight
    ) public {
        contributorCount += 1;
        uint256 newId = contributorCount;
        
        encryptedContributions[newId] = EncryptedContribution({
            contributorId: newId,
            encryptedStyleWeight: encryptedStyleWeight,
            encryptedContentWeight: encryptedContentWeight,
            encryptedUsageCount: FHE.asEuint32(0),
            timestamp: block.timestamp
        });
        
        decryptedContributions[newId] = DecryptedContribution({
            styleWeight: 0,
            contentWeight: 0,
            usageCount: 0,
            isRevealed: false
        });
        
        encryptedRoyaltyBalances[newId] = FHE.asEuint32(0);
        
        emit ContributionAdded(newId, block.timestamp);
    }
    
    function recordModelUsage(
        uint256 contributorId,
        euint32 usageIncrement
    ) public {
        EncryptedContribution storage contrib = encryptedContributions[contributorId];
        contrib.encryptedUsageCount = FHE.add(contrib.encryptedUsageCount, usageIncrement);
    }
    
    function distributeRoyalties(
        euint32 totalAmount
    ) public {
        totalRoyaltyPool = FHE.add(totalRoyaltyPool, totalAmount);
        
        for (uint256 i = 1; i <= contributorCount; i++) {
            EncryptedContribution storage contrib = encryptedContributions[i];
            euint32 contributionScore = FHE.add(
                contrib.encryptedStyleWeight,
                contrib.encryptedContentWeight
            );
            euint32 weightedUsage = FHE.mul(
                contributionScore,
                contrib.encryptedUsageCount
            );
            
            euint32 royaltyShare = FHE.div(
                FHE.mul(weightedUsage, totalAmount),
                totalRoyaltyPool
            );
            
            encryptedRoyaltyBalances[i] = FHE.add(
                encryptedRoyaltyBalances[i],
                royaltyShare
            );
        }
        
        emit RoyaltyDistributed(block.timestamp);
    }
    
    function requestContributionDecryption(
        uint256 contributionId
    ) public onlyContributor(contributionId) {
        EncryptedContribution storage contrib = encryptedContributions[contributionId];
        require(!decryptedContributions[contributionId].isRevealed, "Already decrypted");
        
        bytes32[] memory ciphertexts = new bytes32[](3);
        ciphertexts[0] = FHE.toBytes32(contrib.encryptedStyleWeight);
        ciphertexts[1] = FHE.toBytes32(contrib.encryptedContentWeight);
        ciphertexts[2] = FHE.toBytes32(contrib.encryptedUsageCount);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptContribution.selector);
        requestToContributionId[reqId] = contributionId;
    }
    
    function decryptContribution(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 contributionId = requestToContributionId[requestId];
        require(contributionId != 0, "Invalid request");
        
        EncryptedContribution storage eContrib = encryptedContributions[contributionId];
        DecryptedContribution storage dContrib = decryptedContributions[contributionId];
        require(!dContrib.isRevealed, "Already decrypted");
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        float[] memory results = abi.decode(cleartexts, (float[]));
        
        dContrib.styleWeight = results[0];
        dContrib.contentWeight = results[1];
        dContrib.usageCount = uint256(results[2]);
        dContrib.isRevealed = true;
        
        emit ContributionDecrypted(contributionId);
    }
    
    function requestRoyaltyWithdrawal(
        uint256 contributorId
    ) public onlyContributor(contributorId) {
        euint32 balance = encryptedRoyaltyBalances[contributorId];
        require(FHE.gt(balance, FHE.asEuint32(0)), "No balance to withdraw");
        
        bytes32[] memory ciphertexts = new bytes32[](1);
        ciphertexts[0] = FHE.toBytes32(balance);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptRoyalty.selector);
        requestToContributionId[reqId] = contributorId;
    }
    
    function decryptRoyalty(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 contributorId = requestToContributionId[requestId];
        require(contributorId != 0, "Invalid request");
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        uint32 amount = abi.decode(cleartexts, (uint32));
        encryptedRoyaltyBalances[contributorId] = FHE.sub(
            encryptedRoyaltyBalances[contributorId],
            FHE.asEuint32(amount)
        );
        
        emit RoyaltyWithdrawn(contributorId);
    }
    
    function getEncryptedRoyaltyBalance(
        uint256 contributorId
    ) public view returns (euint32) {
        return encryptedRoyaltyBalances[contributorId];
    }
    
    function compareContributions(
        uint256 contributorId1,
        uint256 contributorId2
    ) public view returns (ebool) {
        EncryptedContribution storage c1 = encryptedContributions[contributorId1];
        EncryptedContribution storage c2 = encryptedContributions[contributorId2];
        
        euint32 score1 = FHE.add(c1.encryptedStyleWeight, c1.encryptedContentWeight);
        euint32 score2 = FHE.add(c2.encryptedStyleWeight, c2.encryptedContentWeight);
        
        return FHE.gt(score1, score2);
    }
    
    function calculateInfluenceScore(
        euint32 styleWeight,
        euint32 contentWeight,
        euint32 usageCount
    ) public pure returns (euint32) {
        euint32 weightedStyle = FHE.mul(styleWeight, FHE.asEuint32(3));
        euint32 weightedContent = FHE.mul(contentWeight, FHE.asEuint32(2));
        
        return FHE.mul(
            FHE.add(weightedStyle, weightedContent),
            usageCount
        );
    }
}