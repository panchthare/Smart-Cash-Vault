// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SmartVault
/// @notice Parallel governance channels with BFT-style n - f thresholds.
///         - Owner add/remove proposals: required = n - f (f = floor((n-1)/3)), expire in 24 hours
///         - Head/Assistant add/remove proposals: required = n - f (f = floor((n-1)/3)), expire in 24 hours
///         - Vault open/close requests: head + assistant approvals, expire in 5 minutes
contract SmartVault {
    /* -------------------------------------------------------------------- */
    /*                             ROLE STATE                                */
    /* -------------------------------------------------------------------- */
    mapping(address => bool) public isOwner;
    address[] private owners;

    address public head;
    address public assistant;

    bool public vaultOpen;

    /* -------------------------------------------------------------------- */
    /*                             CONFIG CONSTANTS                          */
    /* -------------------------------------------------------------------- */
    uint256 public constant OWNER_PROPOSAL_EXPIRY = 24 hours;
    uint256 public constant VAULT_REQUEST_EXPIRY = 5 minutes;

    /* -------------------------------------------------------------------- */
    /*                         OWNER PROPOSALS (BFT n - f)                  */
    /* -------------------------------------------------------------------- */
    enum OwnerAction { NONE, ADD_OWNER, REMOVE_OWNER }

    struct OwnerProposal {
        OwnerAction action;
        address target;
        uint256 votes;
        bool active;
        address proposer;
        uint256 createdAt;
        uint256 expiryAt;
        uint256 totalOwnersSnapshot;
    }

    uint256 private ownerProposalCounter;
    mapping(uint256 => OwnerProposal) private ownerProposals;
    mapping(uint256 => mapping(address => bool)) private ownerProposalVoted;

    /* -------------------------------------------------------------------- */
    /*                         HEAD PROPOSALS (BFT n - f)                   */
    /* -------------------------------------------------------------------- */
    enum HeadAction { NONE, ADD_HEAD, REMOVE_HEAD }
    struct HeadProposal {
        HeadAction action;
        address target;
        uint256 votes;
        bool active;
        address proposer;
        uint256 createdAt;
        uint256 expiryAt;
        uint256 totalOwnersSnapshot;
    }

    uint256 private headProposalCounter;
    mapping(uint256 => HeadProposal) private headProposals;
    mapping(uint256 => mapping(address => bool)) private headProposalVoted;

    /* -------------------------------------------------------------------- */
    /*                     ASSISTANT PROPOSALS (BFT n - f)                  */
    /* -------------------------------------------------------------------- */
    enum AssistantAction { NONE, ADD_ASSISTANT, REMOVE_ASSISTANT }
    struct AssistantProposal {
        AssistantAction action;
        address target;
        uint256 votes;
        bool active;
        address proposer;
        uint256 createdAt;
        uint256 expiryAt;
        uint256 totalOwnersSnapshot;
    }

    uint256 private assistantProposalCounter;
    mapping(uint256 => AssistantProposal) private assistantProposals;
    mapping(uint256 => mapping(address => bool)) private assistantProposalVoted;

    /* -------------------------------------------------------------------- */
    /*                              VAULT REQUESTS                           */
    /* -------------------------------------------------------------------- */
    enum VaultRequestType { NONE, OPEN, CLOSE }
    struct VaultRequest {
        VaultRequestType reqType;
        bool pending;
        bool headApproved;
        bool assistantApproved;
        address requester;
        uint256 createdAt;
        uint256 expiryAt;
    }
    VaultRequest private vaultRequest;

    /* -------------------------------------------------------------------- */
    /*                                  EVENTS                               */
    /* -------------------------------------------------------------------- */
    // Owner events
    event OwnerProposalCreated(uint256 indexed id, OwnerAction action, address target, address proposer, uint256 expiryAt, uint256 ownersSnapshot, uint256 timestamp, address executor, string purpose);
    event OwnerVoted(uint256 indexed id, address voter, uint256 votes, uint256 timestamp, address executor, string purpose);
    event OwnerProposalExecuted(uint256 indexed id, OwnerAction action, address target, uint256 timestamp, address executor, string purpose);
    event OwnerProposalExpired(uint256 indexed id, OwnerAction action, address target, uint256 timestamp, address executor, string purpose);
    event OwnerAdded(address newOwner, uint256 timestamp, address executor, string purpose);
    event OwnerRemoved(address removedOwner, uint256 timestamp, address executor, string purpose);

    // Head events
    event HeadProposalCreatedEvent(uint256 indexed id, HeadAction action, address target, address proposer, uint256 expiryAt, uint256 ownersSnapshot, uint256 timestamp, address executor, string purpose);
    event HeadVotedEvent(uint256 indexed id, address voter, uint256 votes, uint256 timestamp, address executor, string purpose);
    event HeadProposalExecutedEvent(uint256 indexed id, HeadAction action, address target, uint256 timestamp, address executor, string purpose);
    event HeadProposalExpiredEvent(uint256 indexed id, HeadAction action, address target, uint256 timestamp, address executor, string purpose);
    event HeadAdded(address newHead, uint256 timestamp, address executor, string purpose);
    event HeadRemoved(address oldHead, uint256 timestamp, address executor, string purpose);

    // Assistant events
    event AssistantProposalCreatedEvent(uint256 indexed id, AssistantAction action, address target, address proposer, uint256 expiryAt, uint256 ownersSnapshot, uint256 timestamp, address executor, string purpose);
    event AssistantVotedEvent(uint256 indexed id, address voter, uint256 votes, uint256 timestamp, address executor, string purpose);
    event AssistantProposalExecutedEvent(uint256 indexed id, AssistantAction action, address target, uint256 timestamp, address executor, string purpose);
    event AssistantProposalExpiredEvent(uint256 indexed id, AssistantAction action, address target, uint256 timestamp, address executor, string purpose);
    event AssistantAdded(address newAssistant, uint256 timestamp, address executor, string purpose);
    event AssistantRemoved(address oldAssistant, uint256 timestamp, address executor, string purpose);

    // Vault events
    event VaultRequested(VaultRequestType reqType, address requester, uint256 expiryAt, uint256 timestamp, address executor, string purpose);
    event VaultApproved(address who, VaultRequestType reqType, uint256 timestamp, address executor, string purpose);
    event VaultExecuted(VaultRequestType reqType, uint256 timestamp, address executor, string purpose);
    event VaultRequestExpired(uint256 timestamp, address executor, string purpose);
    event VaultRequestCancelled(address who, uint256 timestamp, address executor, string purpose);

    /* -------------------------------------------------------------------- */
    /*                                 MODIFIERS                             */
    /* -------------------------------------------------------------------- */
    modifier onlyOwner() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    modifier onlyHeadOrAssistant() {
        require(msg.sender == head || msg.sender == assistant, "Not head/assistant");
        _;
    }

    /* -------------------------------------------------------------------- */
    /*                               CONSTRUCTOR                             */
    /* -------------------------------------------------------------------- */
    constructor(address[] memory initialOwners) {
        require(initialOwners.length > 0, "At least one owner required");
        for (uint i = 0; i < initialOwners.length; ++i) {
            address a = initialOwners[i];
            require(a != address(0), "Zero owner");
            require(!isOwner[a], "Duplicate owner");
            isOwner[a] = true;
            owners.push(a);
        }
    }

    /* -------------------------------------------------------------------- */
    /*                     OWNER PROPOSAL FUNCTIONS                          */
    /* -------------------------------------------------------------------- */
    function proposeAddOwner(address newOwner) external onlyOwner returns (uint256) {
        require(newOwner != address(0), "Zero address");
        require(!isOwner[newOwner], "Already owner");
        ownerProposalCounter++;
        uint256 id = ownerProposalCounter;
        uint256 snapshot = owners.length;
        OwnerProposal storage p = ownerProposals[id];
        p.action = OwnerAction.ADD_OWNER;
        p.target = newOwner;
        p.votes = 0;
        p.active = true;
        p.proposer = msg.sender;
        p.createdAt = block.timestamp;
        p.expiryAt = block.timestamp + OWNER_PROPOSAL_EXPIRY;
        p.totalOwnersSnapshot = snapshot;
        emit OwnerProposalCreated(id, OwnerAction.ADD_OWNER, newOwner, msg.sender, p.expiryAt, snapshot, block.timestamp, msg.sender, "Propose Add Owner");
        return id;
    }

    function proposeRemoveOwner(address removeOwner) external onlyOwner returns (uint256) {
        require(removeOwner != address(0), "Zero address");
        require(isOwner[removeOwner], "Not an owner");
        ownerProposalCounter++;
        uint256 id = ownerProposalCounter;
        uint256 snapshot = owners.length;
        OwnerProposal storage p = ownerProposals[id];
        p.action = OwnerAction.REMOVE_OWNER;
        p.target = removeOwner;
        p.votes = 0;
        p.active = true;
        p.proposer = msg.sender;
        p.createdAt = block.timestamp;
        p.expiryAt = block.timestamp + OWNER_PROPOSAL_EXPIRY;
        p.totalOwnersSnapshot = snapshot;
        emit OwnerProposalCreated(id, OwnerAction.REMOVE_OWNER, removeOwner, msg.sender, p.expiryAt, snapshot, block.timestamp, msg.sender, "Propose Remove Owner");
        return id;
    }

    function voteOwnerProposal(uint256 proposalId) external onlyOwner {
        OwnerProposal storage p = ownerProposals[proposalId];
        require(p.active, "Inactive proposal");
        require(block.timestamp <= p.expiryAt, "Proposal expired");
        require(!ownerProposalVoted[proposalId][msg.sender], "Already voted");
        ownerProposalVoted[proposalId][msg.sender] = true;
        p.votes++;
        emit OwnerVoted(proposalId, msg.sender, p.votes, block.timestamp, msg.sender, "Vote Owner Proposal");
        _tryExecuteOwnerProposal(proposalId);
    }

    function expireOwnerProposal(uint256 proposalId) external {
        OwnerProposal storage p = ownerProposals[proposalId];
        require(p.active, "Inactive");
        require(block.timestamp > p.expiryAt, "Not expired");
        p.active = false;
        emit OwnerProposalExpired(proposalId, p.action, p.target, block.timestamp, msg.sender, "Expire Owner Proposal");
    }

    function _tryExecuteOwnerProposal(uint256 proposalId) internal {
        OwnerProposal storage p = ownerProposals[proposalId];
        require(p.active, "Inactive");
        uint256 required = _requiredNminusF(p.totalOwnersSnapshot);
        if (p.votes >= required) {
            p.active = false;
            if (p.action == OwnerAction.ADD_OWNER) _addOwner(p.target, "Execute Add Owner");
            else if (p.action == OwnerAction.REMOVE_OWNER) {
                require(isOwner[p.target], "Target no longer owner");
                require(owners.length > 1, "Cannot remove last owner");
                _removeOwner(p.target, "Execute Remove Owner");
            }
            emit OwnerProposalExecuted(proposalId, p.action, p.target, block.timestamp, msg.sender, "Owner Proposal Executed");
        }
    }

    /* -------------------------------------------------------------------- */
    /*                     HEAD PROPOSAL FUNCTIONS                           */
    /* -------------------------------------------------------------------- */
    function proposeAddHead(address newHead) external onlyOwner returns (uint256) {
        require(newHead != address(0), "Zero address");
        require(head != newHead, "Already head");
        headProposalCounter++;
        uint256 id = headProposalCounter;
        uint256 snapshot = owners.length;
        HeadProposal storage p = headProposals[id];
        p.action = HeadAction.ADD_HEAD;
        p.target = newHead;
        p.votes = 0;
        p.active = true;
        p.proposer = msg.sender;
        p.createdAt = block.timestamp;
        p.expiryAt = block.timestamp + OWNER_PROPOSAL_EXPIRY;
        p.totalOwnersSnapshot = snapshot;
        emit HeadProposalCreatedEvent(id, HeadAction.ADD_HEAD, newHead, msg.sender, p.expiryAt, snapshot, block.timestamp, msg.sender, "Propose Add Head");
        return id;
    }

    function proposeRemoveHead(address removeHead) external onlyOwner returns (uint256) {
        require(head != address(0), "No head set");
        require(removeHead == head, "Target must equal current head");
        headProposalCounter++;
        uint256 id = headProposalCounter;
        uint256 snapshot = owners.length;
        HeadProposal storage p = headProposals[id];
        p.action = HeadAction.REMOVE_HEAD;
        p.target = removeHead;
        p.votes = 0;
        p.active = true;
        p.proposer = msg.sender;
        p.createdAt = block.timestamp;
        p.expiryAt = block.timestamp + OWNER_PROPOSAL_EXPIRY;
        p.totalOwnersSnapshot = snapshot;
        emit HeadProposalCreatedEvent(id, HeadAction.REMOVE_HEAD, removeHead, msg.sender, p.expiryAt, snapshot, block.timestamp, msg.sender, "Propose Remove Head");
        return id;
    }

    function voteHeadProposal(uint256 proposalId) external onlyOwner {
        HeadProposal storage p = headProposals[proposalId];
        require(p.active, "Inactive proposal");
        require(block.timestamp <= p.expiryAt, "Proposal expired");
        require(!headProposalVoted[proposalId][msg.sender], "Already voted");
        headProposalVoted[proposalId][msg.sender] = true;
        p.votes++;
        emit HeadVotedEvent(proposalId, msg.sender, p.votes, block.timestamp, msg.sender, "Vote Head Proposal");
        _tryExecuteHeadProposal(proposalId);
    }

    function expireHeadProposal(uint256 proposalId) external {
        HeadProposal storage p = headProposals[proposalId];
        require(p.active, "Inactive");
        require(block.timestamp > p.expiryAt, "Not expired");
        p.active = false;
        emit HeadProposalExpiredEvent(proposalId, p.action, p.target, block.timestamp, msg.sender, "Expire Head Proposal");
    }

    function _tryExecuteHeadProposal(uint256 proposalId) internal {
        HeadProposal storage p = headProposals[proposalId];
        require(p.active, "Inactive");
        uint256 required = _requiredNminusF(p.totalOwnersSnapshot);
        if (p.votes >= required) {
            p.active = false;
            if (p.action == HeadAction.ADD_HEAD) {
                head = p.target;
                emit HeadAdded(p.target, block.timestamp, msg.sender, "Execute Add Head");
            } else if (p.action == HeadAction.REMOVE_HEAD) {
                emit HeadRemoved(head, block.timestamp, msg.sender, "Execute Remove Head");
                head = address(0);
            }
            emit HeadProposalExecutedEvent(proposalId, p.action, p.target, block.timestamp, msg.sender, "Head Proposal Executed");
        }
    }

    /* -------------------------------------------------------------------- */
    /*                  ASSISTANT PROPOSAL FUNCTIONS                         */
    /* -------------------------------------------------------------------- */
    function proposeAddAssistant(address newAssistant) external onlyOwner returns (uint256) {
        require(newAssistant != address(0), "Zero address");
        require(assistant != newAssistant, "Already assistant");
        assistantProposalCounter++;
        uint256 id = assistantProposalCounter;
        uint256 snapshot = owners.length;
        AssistantProposal storage p = assistantProposals[id];
        p.action = AssistantAction.ADD_ASSISTANT;
        p.target = newAssistant;
        p.votes = 0;
        p.active = true;
        p.proposer = msg.sender;
        p.createdAt = block.timestamp;
        p.expiryAt = block.timestamp + OWNER_PROPOSAL_EXPIRY;
        p.totalOwnersSnapshot = snapshot;
        emit AssistantProposalCreatedEvent(id, AssistantAction.ADD_ASSISTANT, newAssistant, msg.sender, p.expiryAt, snapshot, block.timestamp, msg.sender, "Propose Add Assistant");
        return id;
    }

    function proposeRemoveAssistant(address removeAssistant) external onlyOwner returns (uint256) {
        require(assistant != address(0), "No assistant set");
        require(removeAssistant == assistant, "Target must equal current assistant");
        assistantProposalCounter++;
        uint256 id = assistantProposalCounter;
        uint256 snapshot = owners.length;
        AssistantProposal storage p = assistantProposals[id];
        p.action = AssistantAction.REMOVE_ASSISTANT;
        p.target = removeAssistant;
        p.votes = 0;
        p.active = true;
        p.proposer = msg.sender;
        p.createdAt = block.timestamp;
        p.expiryAt = block.timestamp + OWNER_PROPOSAL_EXPIRY;
        p.totalOwnersSnapshot = snapshot;
        emit AssistantProposalCreatedEvent(id, AssistantAction.REMOVE_ASSISTANT, removeAssistant, msg.sender, p.expiryAt, snapshot, block.timestamp, msg.sender, "Propose Remove Assistant");
        return id;
    }

    function voteAssistantProposal(uint256 proposalId) external onlyOwner {
        AssistantProposal storage p = assistantProposals[proposalId];
        require(p.active, "Inactive proposal");
        require(block.timestamp <= p.expiryAt, "Proposal expired");
        require(!assistantProposalVoted[proposalId][msg.sender], "Already voted");
        assistantProposalVoted[proposalId][msg.sender] = true;
        p.votes++;
        emit AssistantVotedEvent(proposalId, msg.sender, p.votes, block.timestamp, msg.sender, "Vote Assistant Proposal");
        _tryExecuteAssistantProposal(proposalId);
    }

    function expireAssistantProposal(uint256 proposalId) external {
        AssistantProposal storage p = assistantProposals[proposalId];
        require(p.active, "Inactive");
        require(block.timestamp > p.expiryAt, "Not expired");
        p.active = false;
        emit AssistantProposalExpiredEvent(proposalId, p.action, p.target, block.timestamp, msg.sender, "Expire Assistant Proposal");
    }

    function _tryExecuteAssistantProposal(uint256 proposalId) internal {
        AssistantProposal storage p = assistantProposals[proposalId];
        require(p.active, "Inactive");
        uint256 required = _requiredNminusF(p.totalOwnersSnapshot);
        if (p.votes >= required) {
            p.active = false;
            if (p.action == AssistantAction.ADD_ASSISTANT) {
                assistant = p.target;
                emit AssistantAdded(p.target, block.timestamp, msg.sender, "Execute Add Assistant");
            } else if (p.action == AssistantAction.REMOVE_ASSISTANT) {
                emit AssistantRemoved(assistant, block.timestamp, msg.sender, "Execute Remove Assistant");
                assistant = address(0);
            }
            emit AssistantProposalExecutedEvent(proposalId, p.action, p.target, block.timestamp, msg.sender, "Assistant Proposal Executed");
        }
    }

    /* -------------------------------------------------------------------- */
    /*                     VAULT REQUEST FUNCTIONS                           */
    /* -------------------------------------------------------------------- */
    function requestVaultOpen() external onlyHeadOrAssistant {
        _startVaultRequest(VaultRequestType.OPEN);
    }

    function requestVaultClose() external onlyHeadOrAssistant {
        _startVaultRequest(VaultRequestType.CLOSE);
    }

    function _startVaultRequest(VaultRequestType t) internal {
        require(!vaultRequest.pending, "Another vault request pending");
        if (t == VaultRequestType.OPEN) require(!vaultOpen, "Vault already open");
        else require(vaultOpen, "Vault already closed");

        vaultRequest.reqType = t;
        vaultRequest.pending = true;
        vaultRequest.headApproved = (msg.sender == head);
        vaultRequest.assistantApproved = (msg.sender == assistant);
        vaultRequest.requester = msg.sender;
        vaultRequest.createdAt = block.timestamp;
        vaultRequest.expiryAt = block.timestamp + VAULT_REQUEST_EXPIRY;

        emit VaultRequested(t, msg.sender, vaultRequest.expiryAt, block.timestamp, msg.sender, "Vault Request Created");

        if (vaultRequest.headApproved && vaultRequest.assistantApproved) _executeVaultRequest();
    }

    function approveVaultRequest() external onlyHeadOrAssistant {
        require(vaultRequest.pending, "No pending request");
        require(block.timestamp <= vaultRequest.expiryAt, "Request expired");
        if (msg.sender == head) vaultRequest.headApproved = true;
        if (msg.sender == assistant) vaultRequest.assistantApproved = true;

        emit VaultApproved(msg.sender, vaultRequest.reqType, block.timestamp, msg.sender, "Approve Vault Request");

        if (vaultRequest.headApproved && vaultRequest.assistantApproved) _executeVaultRequest();
    }

    function cancelVaultRequest() external onlyHeadOrAssistant{
        require(vaultRequest.pending, "No pending request");
        require(msg.sender == vaultRequest.requester, "Only requester can cancel");
        _clearVaultRequest();
        emit VaultRequestCancelled(msg.sender, block.timestamp, msg.sender, "Cancel Vault Request");
    }

    function expireVaultRequest() external onlyHeadOrAssistant {
        require(vaultRequest.pending, "No pending request");
        require(block.timestamp > vaultRequest.expiryAt, "Not expired");
        _clearVaultRequest();
        emit VaultRequestExpired(block.timestamp, msg.sender, "Expire Vault Request");
    }

    function _executeVaultRequest() internal {
        VaultRequestType t = vaultRequest.reqType;
        vaultOpen = (t == VaultRequestType.OPEN);
        emit VaultExecuted(t, block.timestamp, msg.sender, "Vault Executed");
        _clearVaultRequest();
    }

    function _clearVaultRequest() internal {
        vaultRequest.reqType = VaultRequestType.NONE;
        vaultRequest.pending = false;
        vaultRequest.headApproved = false;
        vaultRequest.assistantApproved = false;
        vaultRequest.requester = address(0);
        vaultRequest.createdAt = 0;
        vaultRequest.expiryAt = 0;
    }

    /* -------------------------------------------------------------------- */
    /*                      INTERNAL HELPERS                                 */
    /* -------------------------------------------------------------------- */
    function _addOwner(address a, string memory purpose) internal {
        require(a != address(0), "Zero");
        require(!isOwner[a], "Already owner");
        isOwner[a] = true;
        owners.push(a);
        emit OwnerAdded(a, block.timestamp, msg.sender, purpose);
    }

    function _removeOwner(address a, string memory purpose) internal {
        require(isOwner[a], "Not owner");
        isOwner[a] = false;
        uint256 len = owners.length;
        for (uint256 i = 0; i < len; ++i) {
            if (owners[i] == a) {
                owners[i] = owners[len - 1];
                owners.pop();
                break;
            }
        }
        emit OwnerRemoved(a, block.timestamp, msg.sender, purpose);
    }

    function _requiredNminusF(uint256 snapshotOwners) internal pure returns (uint256) {
        if (snapshotOwners == 0) return 0;
        if (snapshotOwners == 1) return 1;
        uint256 f = (snapshotOwners - 1) / 3;
        uint256 required = snapshotOwners - f;
        if (required < 1) required = 1;
        if (required > snapshotOwners) required = snapshotOwners;
        return required;
    }

    /* -------------------------------------------------------------------- */
    /*                                 VIEWS                                  */
    /* -------------------------------------------------------------------- */
    function getOwners() external view returns (address[] memory) { return owners; }
}

