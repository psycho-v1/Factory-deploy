// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

error NotOwner();
error AlreadyInitialized();
error AlreadyRegistered();
error ZeroAddress();
error DeployFailed();
error CallFailed();
error InsufficientBalance();
error LengthMismatch();
error BadSignature();
error Expired();

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721Minimal {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface IERC1155Minimal {
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;

    function setApprovalForAll(
        address operator,
        bool approved
    ) external;
}

contract PersonalVault {
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant ERC1271_FAIL = 0xffffffff;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant CALL_TYPEHASH =
        keccak256("Call(address target,uint256 value,bytes data)");

    bytes32 private constant EXEC_TYPEHASH =
        keccak256("Execute(Call[] calls,uint256 nonce,uint256 deadline)Call(address target,uint256 value,bytes data)");

    address public owner;
    address public factory;
    bool public initialized;
    uint256 public nonce;

    event Initialized(address indexed owner, address indexed factory);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event ContractDeployed(address indexed deployed, uint256 value, bytes32 salt, bool create2);
    event Executed(address indexed target, uint256 value, bytes data, bytes result);
    event BatchExecuted(uint256 count);
    event GasRefunded(address indexed to, uint256 amount);
    event SignedExecuted(address indexed signer, uint256 nonce, address indexed relayer);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    function initialize(address owner_) external {
        if (initialized) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroAddress();
        initialized = true;
        owner = owner_;
        factory = msg.sender;
        emit Initialized(owner_, msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        _sendNative(to, amount);
    }

    function sendNative(address to, uint256 amount) external onlyOwner {
        _sendNative(to, amount);
    }

    function sendToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        bool ok = IERC20Minimal(token).transfer(to, amount);
        if (!ok) revert CallFailed();
    }

    function approveToken(address token, address spender, uint256 amount) external onlyOwner {
        if (token == address(0) || spender == address(0)) revert ZeroAddress();
        bool ok = IERC20Minimal(token).approve(spender, amount);
        if (!ok) revert CallFailed();
    }

    function sendNFT(address token, address to, uint256 tokenId) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC721Minimal(token).safeTransferFrom(address(this), to, tokenId);
    }

    function approveNFT(address token, address to, uint256 tokenId) external onlyOwner {
        IERC721Minimal(token).approve(to, tokenId);
    }

    function setNFTApprovalForAll(address token, address operator, bool approved) external onlyOwner {
        IERC721Minimal(token).setApprovalForAll(operator, approved);
    }

    function sendERC1155(
        address token,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external onlyOwner {
        IERC1155Minimal(token).safeTransferFrom(address(this), to, id, amount, data);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return 0xbc197c81;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return
            id == 0x01ffc9a7 ||
            id == 0x1626ba7e ||
            id == 0x150b7a02 ||
            id == 0x4e2312e0;
    }

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (bytes memory result) {
        result = _call(target, value, data);
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external onlyOwner {
        uint256 len = targets.length;
        if (len != values.length || len != datas.length) revert LengthMismatch();
        for (uint256 i; i < len; ) {
            _call(targets[i], values[i], datas[i]);
            unchecked { ++i; }
        }
        emit BatchExecuted(len);
    }

    function deploy(
        bytes memory bytecode,
        uint256 value,
        bool refundGas
    ) external onlyOwner returns (address deployed) {
        deployed = _create(bytecode, value, bytes32(0), false);
        if (refundGas) _refundGas(gasleft());
    }

    function deploy2(
        bytes32 salt,
        bytes memory bytecode,
        uint256 value,
        bool refundGas
    ) external onlyOwner returns (address deployed) {
        deployed = _create(bytecode, value, salt, true);
        if (refundGas) _refundGas(gasleft());
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (_recover(hash, signature) == owner) return ERC1271_MAGIC;
        return ERC1271_FAIL;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PersonalVault"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function executeSigned(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        uint256 deadline,
        bool refundRelayer,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert Expired();

        uint256 len = targets.length;
        if (len != values.length || len != datas.length) revert LengthMismatch();

        bytes32 structHash = keccak256(
            abi.encode(
                EXEC_TYPEHASH,
                _callsHash(targets, values, datas),
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(bytes2(0x1901), domainSeparator(), structHash)
        );

        if (_recover(digest, signature) != owner) revert BadSignature();

        uint256 usedNonce = nonce;
        unchecked { ++nonce; }

        uint256 startGas = gasleft();

        for (uint256 i; i < len; ) {
            _call(targets[i], values[i], datas[i]);
            unchecked { ++i; }
        }

        emit SignedExecuted(owner, usedNonce, msg.sender);
        emit BatchExecuted(len);

        if (refundRelayer) {
            uint256 used = startGas - gasleft();
            uint256 refund = (used + 2300) * tx.gasprice;
            uint256 available = address(this).balance;
            if (refund > available) refund = available;
            if (refund > 0) {
                (bool ok,) = payable(msg.sender).call{value: refund}("");
                if (ok) emit GasRefunded(msg.sender, refund);
            }
        }
    }

    function _callsHash(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](targets.length);
        for (uint256 i; i < targets.length; ) {
            hashes[i] = keccak256(
                abi.encode(
                    CALL_TYPEHASH,
                    targets[i],
                    values[i],
                    keccak256(datas[i])
                )
            );
            unchecked { ++i; }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _call(
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (bytes memory result) {
        if (target == address(0)) revert ZeroAddress();
        if (address(this).balance < value) revert InsufficientBalance();
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) revert CallFailed();
        emit Executed(target, value, data, result);
    }

    function _sendNative(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (address(this).balance < amount) revert InsufficientBalance();
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert CallFailed();
        emit Withdrawn(to, amount);
    }

    function _create(
        bytes memory bytecode,
        uint256 value,
        bytes32 salt,
        bool useCreate2
    ) internal returns (address deployed) {
        if (address(this).balance < value) revert InsufficientBalance();
        if (useCreate2) {
            assembly {
                deployed := create2(value, add(bytecode, 0x20), mload(bytecode), salt)
            }
        } else {
            assembly {
                deployed := create(value, add(bytecode, 0x20), mload(bytecode))
            }
        }
        if (deployed == address(0)) revert DeployFailed();
        emit ContractDeployed(deployed, value, salt, useCreate2);
    }

    function _refundGas(uint256 startGas) internal {
        uint256 used = startGas > gasleft() ? startGas - gasleft() : 0;
        uint256 refund = (used + 2300) * tx.gasprice;
        uint256 available = address(this).balance;
        if (refund > available) refund = available;
        if (refund == 0) return;
        (bool ok,) = payable(owner).call{value: refund}("");
        if (ok) emit GasRefunded(owner, refund);
    }

    function _recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(hash, v, r, s);
    }
}

contract VaultFactory {
    address public immutable implementation;
    address public owner;

    mapping(address => address) public vaultOf;
    mapping(address => address) public userOf;
    address[] public users;

    event FactoryOwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event VaultRegistered(address indexed user, address indexed vault, uint256 index);

    constructor() {
        owner = msg.sender;
        implementation = address(new PersonalVault());
    }

    function transferFactoryOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        emit FactoryOwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function userCount() external view returns (uint256) {
        return users.length;
    }

    function hasVault(address user) external view returns (bool) {
        return vaultOf[user] != address(0);
    }

    function predictVault(address user) public view returns (address) {
        return _predictClone(implementation, bytes32(uint256(uint160(user))));
    }

    function registerVault() external returns (address vault) {
        if (vaultOf[msg.sender] != address(0)) revert AlreadyRegistered();

        bytes32 salt = bytes32(uint256(uint160(msg.sender)));
        vault = _clone2(implementation, salt);

        PersonalVault(payable(vault)).initialize(msg.sender);

        vaultOf[msg.sender] = vault;
        userOf[vault] = msg.sender;
        users.push(msg.sender);

        emit VaultRegistered(msg.sender, vault, users.length - 1);
    }

    function _clone2(address impl, bytes32 salt) internal returns (address instance) {
        bytes memory code = _cloneBytecode(impl);
        assembly {
            instance := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (instance == address(0)) revert DeployFailed();
    }

    function _predictClone(address impl, bytes32 salt) internal view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(_cloneBytecode(impl))
            )
        );
        return address(uint160(uint256(hash)));
    }

    function _cloneBytecode(address impl) internal pure returns (bytes memory code) {
        code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            impl,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
    }
}
