// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.10;

import {ReentrancyGuard} from "@rari-capital/solmate/src/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC721TransferHelper} from "../../../transferHelpers/ERC721TransferHelper.sol";
import {IncomingTransferSupportV1} from "../../../common/IncomingTransferSupport/V1/IncomingTransferSupportV1.sol";
import {FeePayoutSupportV1} from "../../../common/FeePayoutSupport/FeePayoutSupportV1.sol";
import {ModuleNamingSupportV1} from "../../../common/ModuleNamingSupport/ModuleNamingSupportV1.sol";

import {IAsksOmnibus} from "./IAsksOmnibus.sol";
import {AsksDataStorage} from "./AsksDataStorage.sol";

/// @title Asks
/// @author jgeary
contract AsksOmnibus is ReentrancyGuard, IncomingTransferSupportV1, FeePayoutSupportV1, ModuleNamingSupportV1, AsksDataStorage {
    /// @notice The ZORA ERC-721 Transfer Helper
    ERC721TransferHelper public immutable erc721TransferHelper;

    /// @param _erc20TransferHelper The ZORA ERC-20 Transfer Helper address
    /// @param _erc721TransferHelper The ZORA ERC-721 Transfer Helper address
    /// @param _royaltyEngine The Manifold Royalty Engine address
    /// @param _protocolFeeSettings The ZORA Protocol Fee Settings address
    /// @param _weth The WETH token address
    constructor(
        address _erc20TransferHelper,
        address _erc721TransferHelper,
        address _royaltyEngine,
        address _protocolFeeSettings,
        address _weth
    )
        IncomingTransferSupportV1(_erc20TransferHelper)
        FeePayoutSupportV1(_royaltyEngine, _protocolFeeSettings, _weth, ERC721TransferHelper(_erc721TransferHelper).ZMM().registrar())
        ModuleNamingSupportV1("Reserve Auction Listing ERC-20")
    {
        erc721TransferHelper = ERC721TransferHelper(_erc721TransferHelper);
    }

    /// @notice Implements EIP-165 for standard interface detection
    /// @dev `0x01ffc9a7` is the IERC165 interface id
    /// @param _interfaceId The identifier of a given interface
    /// @return If the given interface is supported
    function supportsInterface(bytes4 _interfaceId) external pure returns (bool) {
        return _interfaceId == type(IAsksOmnibus).interfaceId || _interfaceId == 0x01ffc9a7;
    }

    function createAskMinimal(
        address _tokenContract,
        uint256 _tokenId,
        uint96 _askPrice
    ) external nonReentrant {
        // Get the owner of the specified token
        address tokenOwner = IERC721(_tokenContract).ownerOf(_tokenId);
        // Ensure the caller is the owner or an approved operator
        require(msg.sender == tokenOwner || IERC721(_tokenContract).isApprovedForAll(tokenOwner, msg.sender), "ONLY_TOKEN_OWNER_OR_OPERATOR");

        StoredAsk storage ask = askForNFT[_tokenContract][_tokenId];
        ask.features = 0;
        ask.seller = tokenOwner;
        ask.price = uint96(_askPrice);
    }

    function createAsk(
        address _tokenContract,
        uint256 _tokenId,
        uint96 _expiry,
        uint256 _askPrice,
        address _sellerFundsRecipient,
        address _askCurrency,
        address _buyer,
        uint16 _findersFeeBps,
        AsksDataStorage.ListingFee memory _listingFee,
        AsksDataStorage.TokenGate memory _tokenGate
    ) external nonReentrant {
        address tokenOwner = IERC721(_tokenContract).ownerOf(_tokenId);

        require(
            msg.sender == tokenOwner || IERC721(_tokenContract).isApprovedForAll(tokenOwner, msg.sender),
            "createAsk must be token owner or operator"
        );
        require(erc721TransferHelper.isModuleApproved(msg.sender), "createAsk must approve AsksOmnibus module");
        require(
            IERC721(_tokenContract).isApprovedForAll(tokenOwner, address(erc721TransferHelper)),
            "createAsk must approve ERC721TransferHelper as operator"
        );
        require(_askPrice <= type(uint96).max, "INVALID_PRICE");

        StoredAsk storage ask = askForNFT[_tokenContract][_tokenId];

        ask.features = 0;

        if (_listingFee.listingFeeBps > 0) {
            require(_listingFee.listingFeeBps <= 10000, "INVALID_LISTING_FEE");
            _setListingFee(ask, _listingFee.listingFeeBps, _listingFee.listingFeeRecipient);
        }

        if (_findersFeeBps > 0) {
            require(_findersFeeBps <= 10000, "createAsk finders fee bps must be less than or equal to 10000");
            require(_findersFeeBps <= 10000, "createAsk finders fee bps must be less than or equal to 10000");
            _setFindersFee(ask, _findersFeeBps);
        }

        if (_tokenGate.token != address(0)) {
            require(_tokenGate.minAmount > 0, "Min amt cannot be 0");
            _setTokenGate(ask, _tokenGate.token, _tokenGate.minAmount);
        }

        if (_expiry > 0 || (_sellerFundsRecipient != address(0) && _sellerFundsRecipient != tokenOwner)) {
            require(_expiry == 0 || _expiry > block.timestamp, "Expiry must be in the future");
            _setExpiryAndFundsRecipient(ask, _expiry, _sellerFundsRecipient);
        }

        if (_askCurrency != address(0)) {
            _setERC20Currency(ask, _askCurrency);
        }

        if (_buyer != address(0)) {
            _setBuyer(ask, _buyer);
        }

        ask.seller = tokenOwner;
        ask.price = uint96(_askPrice);

        // emit AskCreated(_tokenContract, _tokenId, askForNFT[_tokenContract][_tokenId]);
    }

    function cancelAsk(address _tokenContract, uint256 _tokenId) external nonReentrant {
        // Get the auction for the specified token
        StoredAsk storage ask = askForNFT[_tokenContract][_tokenId];

        // Ensure the caller is the seller or a new owner of the token
        require(
            msg.sender == ask.seller ||
                msg.sender == IERC721(_tokenContract).ownerOf(_tokenId) ||
                IERC721(_tokenContract).isApprovedForAll(ask.seller, msg.sender) ||
                IERC721(_tokenContract).isApprovedForAll(IERC721(_tokenContract).ownerOf(_tokenId), msg.sender),
            "ONLY_SELLER_OR_OPERATOR_OR_TOKEN_OWNER"
        );

        //emit AuctionCanceled(_tokenContract, _tokenId, _getFullAuction(auction));

        // Remove the auction from storage
        delete askForNFT[_tokenContract][_tokenId];
    }

    function fillAsk(
        address _tokenContract,
        uint256 _tokenId,
        uint256 _price,
        address _currency,
        address _finder
    ) external payable nonReentrant {
        // Get the ask for the specified token
        StoredAsk storage ask = askForNFT[_tokenContract][_tokenId];

        // Cache the seller
        address seller = ask.seller;

        // Ensure the ask is active
        require(seller != address(0), "INACTIVE_ASK");

        // Cache the price
        uint256 price = uint256(ask.price);

        // Ensure the specified price matches the ask price
        require(_price == price, "MUST_MATCH_PRICE");

        // Cache the currency
        address currency = _getERC20CurrencyWithFallback(ask);

        // Ensure the specified currency matches the ask currency
        require(_currency == currency, "MUST_MATCH_CURRENCY");

        address fundsRecipient = ask.seller;

        if (_hasFeature(ask.features, FEATURE_MASK_RECIPIENT_OR_EXPIRY)) {
            (uint96 expiry, address storedFundsRecipient) = _getExpiryAndFundsRecipient(ask);
            fundsRecipient = storedFundsRecipient;
            require(expiry >= block.timestamp, "Ask has expired");
        }

        if (_hasFeature(ask.features, FEATURE_MASK_TOKEN_GATE)) {
            AsksDataStorage.TokenGate memory tokenGate = _getAskTokenGate(ask);
            require(IERC20(tokenGate.token).balanceOf(msg.sender) >= tokenGate.minAmount, "Token gate not satisfied");
        }

        if (_hasFeature(ask.features, FEATURE_MASK_BUYER)) {
            require(msg.sender == _getBuyerWithFallback(ask), "Ask is reserved for a specific buyer");
        }

        // Transfer the ask price from the buyer
        // If ETH, this reverts if the buyer did not attach enough
        // If ERC-20, this reverts if the buyer did not approve the ERC20TransferHelper or does not own the specified tokens
        _handleIncomingTransfer(price, currency);

        // Payout associated token royalties, if any
        (uint256 remainingProfit, ) = _handleRoyaltyPayout(_tokenContract, _tokenId, price, currency, 300000);

        // Payout the module fee, if configured
        remainingProfit = _handleProtocolFeePayout(remainingProfit, currency);

        if (_hasFeature(ask.features, FEATURE_MASK_LISTING_FEE)) {
            ListingFee memory listingFeeInfo = _getListingFee(ask);
            // Get the listing fee from the remaining profit
            uint256 listingFee = (remainingProfit * listingFeeInfo.listingFeeBps) / 10000;

            // Transfer the amount to the listing fee recipient
            _handleOutgoingTransfer(listingFeeInfo.listingFeeRecipient, listingFee, currency, 50000);

            // Update the remaining profit
            remainingProfit -= listingFee;
        }

        if (_finder != address(0) && _hasFeature(ask.features, FEATURE_MASK_FINDERS_FEE)) {
            uint16 findersFeeBps = _getFindersFee(ask);
            // Get the listing fee from the remaining profit
            uint256 findersFee = (remainingProfit * findersFeeBps) / 10000;

            // Transfer the amount to the listing fee recipient
            _handleOutgoingTransfer(_finder, findersFee, currency, 50000);

            // Update the remaining profit
            remainingProfit -= findersFee;
        }

        // Transfer the remaining profit to the seller
        _handleOutgoingTransfer(fundsRecipient, remainingProfit, currency, 50000);

        // Transfer the NFT to the buyer
        // Reverts if the seller did not approve the ERC721TransferHelper or no longer owns the token
        erc721TransferHelper.transferFrom(_tokenContract, seller, msg.sender, _tokenId);

        // emit AskFilled(_tokenContract, _tokenId, msg.sender, ask);

        // Remove the ask from storage
        delete askForNFT[_tokenContract][_tokenId];
    }
}
