from vyper.interfaces import ERC20

AAVE_LENDING_POOL: constant(address) = 0x398eC7346DcD622eDc5ae82352F02bE94C62d119
AAVE_LENDING_POOL_CORE: constant(address) = 0x3dfd23A6c5E8BbcFc9581d2E864a68feb6a076d3
AAVE_REFERRAL_CODE: constant(uint256) = 0


interface aToken:
    def balanceOf(_owner: address) -> uint256: view
    def redeem(_amount: uint256): nonpayable

interface LendingPool:
    def repay(_reserve: address, _amount: uint256, _onBehalfOf: address): payable
    def getUserReserveData(_reserve: address, _user: address) -> (uint256[9], bool): view

interface LiquidityGaugeAave:
    def balanceOf(_owner: address) -> uint256: view
    def liquidate(_target: address, _liquidator: address) -> bool: nonpayable


liquidity_gauge: address
owner: address
lp_token: address
atoken: address
is_approved: HashMap[address, bool]


@external
def __init__():
    self.owner = msg.sender


@external
def initialize(_owner: address, _lp_token: address, _atoken: address) -> bool:
    assert self.owner == ZERO_ADDRESS

    self.liquidity_gauge = msg.sender
    self.owner = _owner
    self.lp_token = _lp_token
    self.atoken = _atoken
    assert ERC20(_lp_token).approve(AAVE_LENDING_POOL_CORE, MAX_UINT256)

    return True


@external
def deposit(_amount: uint256) -> bool:
    assert msg.sender == self.liquidity_gauge

    raw_call(
        AAVE_LENDING_POOL,
        concat(
            method_id("deposit(address,uint256,uint16)"),
            convert(self.lp_token, bytes32),        # address
            convert(_amount, bytes32),              # uint256
            convert(AAVE_REFERRAL_CODE, bytes32)    # uint16
        )
    )

    return True


@external
def borrow(_token: address, _amount: uint256, _interest_rate_mode: uint256) -> bool:
    _owner: address = self.owner
    assert msg.sender == _owner

    raw_call(
        AAVE_LENDING_POOL,
        concat(
            method_id("borrow(address,uint256,uint256,uint16)"),
            convert(_token, bytes32),               # underlying asset
            convert(_amount, bytes32),              # amount to borrow
            convert(_interest_rate_mode, bytes32),  # interest rate mode: 1 = stable, 2 = variable
            convert(AAVE_REFERRAL_CODE, bytes32)    # uint16
        )
    )

    _response: Bytes[32] = raw_call(
        _token,
        concat(
            method_id("transfer(address,uint256)"),
            convert(_owner, bytes32),
            convert(_amount, bytes32)
        ),
        max_outsize=32
    )
    if len(_response) > 0:
        assert convert(_response, bool), "Transfer failed!"

    return True


@external
def repay(_token: address, _amount: uint256) -> bool:
    if not self.is_approved[_token]:
        _response: Bytes[32] = raw_call(
           _token,
            concat(
                method_id("approve(address,uint256)"),
                convert(AAVE_LENDING_POOL_CORE, bytes32),
                convert(MAX_UINT256, bytes32)
            ),
            max_outsize=32
        )
        if len(_response) != 0:
            assert convert(_response, bool)
        self.is_approved[_token] = True

    _reserve_data: uint256[9] = LendingPool(AAVE_LENDING_POOL).getUserReserveData(_token, self)[0]
    _repay_amount: uint256 = _reserve_data[1] + _reserve_data[6]

    if _amount != MAX_UINT256:
        if _amount > _repay_amount:
            raise "Repayment exceeds owed amount"
        _repay_amount = _amount

    _response: Bytes[32] = raw_call(
        _token,
        concat(
            method_id("transferFrom(address,address,uint256)"),
            convert(msg.sender, bytes32),
            convert(self, bytes32),
            convert(_repay_amount, bytes32),
        ),
        max_outsize=32
    )
    if len(_response) != 0:
        assert convert(_response, bool)

    LendingPool(AAVE_LENDING_POOL).repay(_token, _repay_amount, self)

    return True


@external
def withdraw(_amount: uint256) -> bool:
    assert msg.sender == self.liquidity_gauge

    _withdraw_amount: uint256 = _amount
    if _amount == MAX_UINT256:
        _withdraw_amount = aToken(self.atoken).balanceOf(self)

    aToken(self.atoken).redeem(_withdraw_amount)

    assert ERC20(self.lp_token).transfer(self.owner, _withdraw_amount)

    return True


@view
@external
def liquidation_amount() -> uint256:
    _actual_balance: uint256 = aToken(self.atoken).balanceOf(self)
    _expected_balance: uint256 = LiquidityGaugeAave(self.liquidity_gauge).balanceOf(self.owner)
    if _actual_balance >= _expected_balance:
        return 0
    return _expected_balance - _actual_balance


@external
def liquidate() -> bool:
    assert LiquidityGaugeAave(self.liquidity_gauge).liquidate(self.owner, msg.sender)

    return True