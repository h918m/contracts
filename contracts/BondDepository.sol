// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;
pragma abicoder v2;

import "./libraries/SafeMath.sol";
import "./libraries/Address.sol";
import "./libraries/SafeERC20.sol";

import "./interfaces/ITreasury.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/ITeller.sol";

contract OlympusBondDepository {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  /* ======== EVENTS ======== */

  event BeforeBond(uint256 index, uint256 price, uint256 internalPrice, uint256 debtRatio);
  event CreateBond(uint256 index, uint256 payout, uint256 expires);

  modifier onlyController() {
    require(msg.sender == controller, "Only controller");
    _;
  }

  /* ======== STRUCTS ======== */

  // Info about each type of bond
  struct Bond {
    IERC20 principal; // token to accept as payment
    IOracle oracle; // assetPrice() should return price of principal in OHM
    Terms terms; // terms of bond
    uint256 capacity; // budget remaining
    bool capacityInPrincipal; // capacity limit is in payout or principal terms
    uint256 totalDebt; // total debt from bond (in OHM)
    uint256 last; // timestamp of last bond
  }

  // Info for creating new bonds
  struct Terms {
    uint256 controlVariable; // scaling variable for price
    uint256 conclusion; // timestamp when bond no longer offered
    bool fixedTerm; // fixed term or fixed expiration
    uint256 vesting; // term in seconds if fixedTerm == true, expiration timestamp if not
    uint256 maxDebt; // max OHM debt accrued at a time
  }

  struct Global {
    uint256 decayRate; // time in seconds to decay debt to zero.
    uint256 maxPayout; // percentage total supply. 9 decimals.
  }

  /* ======== STATE VARIABLES ======== */

  mapping(uint256 => Bond) public bonds;
  address[] public ids; // bond IDs

  Global public global;

  ITeller public teller; // handles payment
  address public controller; // adds or deprecated bonds

  ITreasury internal immutable treasury;
  IERC20 internal immutable ohm;

    /* ======== CONSTRUCTOR ======== */

    constructor(address _ohm, address _treasury) {
      require(_ohm != address(0), "Zero address: OHM");
      ohm = IERC20(_ohm);
      require(_treasury != address(0), "Zero address: Treasury");
      treasury = ITreasury(_treasury);
    }

    /* ======== POLICY FUNCTIONS ======== */

    /**
     * On creating bonds: New bond is created with a principal token to purchase,
     * an oracle quoting an 8 decimal price of that token in OHM, a budget capacity
     * (specified as in OHM or in principal token terms), a timestamp when the
     * bond concludes, and a vesting term or expiration timestamp dictated by
     * _fixedTerm being true or false, respectively.
     * 
     * The contract computes a BCV based on the amount of OHM to spend or principal
     * to buy, and the intended time to do it in (time from initialization to conclusion).
     * The bond is initialized with an amount of initial debt, which should start it
     * at the oracle price. Debt will decay from there to open discounts.
     */

    /**
    * @notice creates a new bond type
    * @param _principal address
    * @param _oracle address
    * @param _capacity uint256
    * @param _inPrincipal bool
    * @param _conclusion uint256
    * @param _fixedTerm bool
    * @param _vesting uint256
    * @return id_ uint256
    */
  function addBond(
    IERC20 _principal,
    IOracle _oracle,
    uint256 _capacity,
    bool _inPrincipal,
    uint256 _conclusion,
    bool _fixedTerm,
    uint256 _vesting
  ) external onlyController returns (uint256 id_) {
    (uint targetDebt, uint256 bcv) = _compute(_capacity, _inPrincipal, _conclusion, _oracle);
    
    _checkLengths(_conclusion, _vesting, _fixedTerm);

    Terms memory terms = Terms({
      controlVariable: bcv, 
      conclusion: _conclusion,
      fixedTerm: _fixedTerm, 
      vesting: _vesting,
      maxDebt: targetDebt * 3 // exists to hedge tail risk. wide buffer important so as not to impede functionality.
    });
    
    Bond memory bond = Bond({
      principal: _principal, 
      oracle: _oracle, 
      terms: terms, 
      totalDebt: targetDebt, 
      last: block.timestamp, 
      capacity: _capacity, 
      capacityInPrincipal: _inPrincipal
    });
    
    id_ = ids.length;
    bonds[id_] = bond;
    ids.push(address(_principal));
  }

  /**
   * @notice disable existing bond
   * @param _bid uint
   */
  function deprecateBond(uint256 _bid) external onlyController {
    bonds[_bid].capacity = 0;
  }

  /**
   * @notice set teller contract
   * @param _teller address
   */
  function setTeller(address _teller) external onlyController {
    require(address(teller) == address(0), "Teller is set");
    require(_teller != address(0), "Zero address: Teller");
    teller = ITeller(_teller);
  }

  /**
   * @notice sets address that creates/disables bonds
   * @param _controller address
   */
  function setController(address _controller) external onlyController {
    require(_controller != address(0), "Zero address: Controller");
    controller = _controller;
  }

  /* ======== MUTABLE FUNCTIONS ======== */

  /**
   * @notice deposit bond
   * @param _depositor address
   * @param _bid uint256
   * @param _amount uint256
   * @param _maxPrice uint256
   * @param _feo address
   * @return payout_ uint256
   * @return index_ uint256
   */
  function deposit(
    address _depositor,
    uint256 _bid,
    uint256 _amount,
    uint256 _maxPrice,
    address _feo
  ) external returns (uint256 payout_, uint256 index_) {
    require(_depositor != address(0), "Invalid address");
    require(_maxPrice >= bondPrice(_bid), "Slippage limit: more than max price");

    Bond storage info = bonds[_bid];
    _beforeBond(info, _bid);

    payout_ = payoutFor(_amount, _bid); // payout to bonder is computed

    uint256 cap = payout_;
    if (info.capacityInPrincipal) { // capacity is in principal terms
      cap = _amount; 
    } 
    require(info.capacity >= cap, "Capacity overflow"); // ensure there is remaining capacity
    info.capacity -= cap;

    _payoutWithinBounds(payout_);
    info.totalDebt += payout_; // increase total debt

    uint256 expiration = info.terms.vesting;
    if (info.terms.fixedTerm) {
      expiration += block.timestamp;
    }

    emit CreateBond(_bid, payout_, expiration);

    // user info stored with teller
    index_ = teller.newBond(_depositor, _bid, payout_, expiration, _feo);

    info.principal.safeTransferFrom(msg.sender, address(this), _amount);
    info.principal.safeTransfer(address(treasury), _amount); // send payout to treasury
  }

  /* ======== INTERNAL FUNCTIONS ======== */

  // checks and event before bond
  function _beforeBond(Bond memory _info, uint256 _bid) internal {
    require(block.timestamp < _info.terms.conclusion, "Bond concluded");

    decayDebt(_bid);

    emit BeforeBond(_bid, bondPriceInUSD(_bid), bondPrice(_bid), debtRatio(_bid));

    require(_info.totalDebt <= _info.terms.maxDebt, "Max debt exceeded");
  }

  // reduce total debt based on time passed
  function decayDebt(uint256 _bid) internal {
    bonds[_bid].totalDebt -= debtDecay(_bid);
    bonds[_bid].last = block.timestamp;
  }

  // ensure payout is not too large or small
  function _payoutWithinBounds(uint256 _payout) internal view {
    require(_payout >= 10000000, "Bond too small"); // must be > 0.01 OHM ( underflow protection )
    require(_payout <= maxPayout(), "Bond too large"); // global max bond size
  }

  /**
   * @notice compute target debt and BCV for bond
   * @return targetDebt_ uint256
   * @return bcv_ uint256
   */
  function _compute(
    uint256 _capacity, 
    bool _inPrincipal, 
    uint256 _conclusion, 
    IOracle _oracle
  ) internal view returns (uint256 targetDebt_, uint256 bcv_) {
    uint256 capacity = _capacity;
    if (_inPrincipal) {
      capacity = _capacity * _oracle.assetPrice() / 1e8;
    }

    uint256 programLength = _conclusion - block.timestamp;
    targetDebt_ = capacity * global.decayRate / programLength;
    uint256 discountedPrice = _oracle.assetPrice() * 98 / 100; // assume average discount of 2%
    // (* 10) below comes from div by 1e8 (oracle) and mul by 1e9 (OHM)
    bcv_ = discountedPrice * ohm.totalSupply() * 10 / targetDebt_;
  }
  
  // ensure bond times are appropriate
  function _checkLengths(uint256 _conclusion, uint256 _vesting, bool _fixedTerm) internal view {
    require(_conclusion > block.timestamp + 5e6, "Conclusion must be >6 days in future");
    if (!_fixedTerm) {
      require(_vesting >= _conclusion, "Bond must conclude before expiration");
    } else {
      require(_vesting >= 5e6, "Bond must last more than 6 days");
    }
  }

  /* ======== VIEW FUNCTIONS ======== */

  // PAYOUT

  /**
   * @notice determine maximum bond size
   * @return uint256
   */
  function maxPayout() public view returns (uint256) {
    return ohm.totalSupply() * global.maxPayout / 1e9;
  }

  /**
   * @notice payout due for amount of token
   * @param _amount uint256
   * @param _bid uint256
   * @return uint256
   */
  function payoutFor(uint256 _amount, uint256 _bid) public view returns (uint256) {
    uint inOhmDecimals = _amount * (10 ** ohm.decimals()) / (10 ** bonds[_bid].principal.decimals());
    return inOhmDecimals * 1e9 / bondPrice(_bid);
  }

  // BOND PRICE

  /**
   * @notice calculate current bond premium
   * @param _bid uint256
   * @return uint256
   */
  function bondPrice(uint256 _bid) public view returns (uint256) {
    return bonds[_bid].terms.controlVariable * debtRatio(_bid) / 1e9;
  }

  /**
   * @notice converts bond price to USD value
   * @param _bid uint256
   * @return uint256
   */
  function bondPriceInUSD(uint256 _bid) public view returns (uint256) {
    return bondPrice(_bid) * bonds[_bid].oracle.assetPrice() / 1e8;
  }

  // DEBT

  /**
   * @notice calculate current ratio of debt to OHM supply
   * @param _bid uint256
   * @return uint256
   */
  function debtRatio(uint256 _bid) public view returns (uint256) {
    return currentDebt(_bid) * 1e9 / ohm.totalSupply();
  }

  /**
   * @notice calculate debt factoring in decay
   * @param _bid uint256
   * @return uint256
   */
  function currentDebt(uint256 _bid) public view returns (uint256) {
    return bonds[_bid].totalDebt - debtDecay(_bid);
  }

  /**
   * @notice amount to decay total debt by
   * @param _bid uint256
   * @return decay_ uint256
   */
  function debtDecay(uint256 _bid) public view returns (uint256 decay_) {
    Bond memory bond = bonds[_bid];
    uint256 timeSinceLast = block.timestamp - bond.last;

    decay_ = bond.totalDebt * timeSinceLast / global.decayRate;

    if (decay_ > bond.totalDebt) {
      decay_ = bond.totalDebt;
    }
  }

  // BOND TYPE INFO

  /**
   * @notice returns data about a bond type
   * @param _bid uint256
   * @return principal_ address
   * @return oracle_ address
   * @return totalDebt_ uint256
   * @return lastBondCreatedAt_ uint256
   */
  function bondInfo(uint256 _bid)
    external
    view
    returns (
      address principal_,
      address oracle_,
      uint256 totalDebt_,
      uint256 lastBondCreatedAt_
    )
  {
    Bond memory info = bonds[_bid];
    principal_ = address(info.principal);
    oracle_ = address(info.oracle);
    totalDebt_ = info.totalDebt;
    lastBondCreatedAt_ = info.last;
  }

  /**
   * @notice returns terms for a bond type
   * @param _bid uint
   * @return controlVariable_ uint256
   * @return conclusion_ uint256
   * @return fixedTerm_ bool
   * @return vesting_ uint256
   * @return maxDebt_ uint256
   */
  function bondTerms(uint256 _bid)
    external
    view
    returns (
      uint256 controlVariable_,
      uint256 conclusion_,
      bool fixedTerm_,
      uint256 vesting_,
      uint256 maxDebt_
    )
  {
    Terms memory terms = bonds[_bid].terms;
    controlVariable_ = terms.controlVariable;
    conclusion_ = terms.conclusion;
    fixedTerm_ = terms.fixedTerm;
    vesting_ = terms.vesting;
    maxDebt_ = terms.maxDebt;
  }
}
