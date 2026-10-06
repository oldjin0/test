// 모듈 사이에서 공유하는 런타임 상태
export const S = {
  save: null,      // 영구 저장 데이터
  G: null,         // 진행 중인 한 판
  scene: 'title',  // title | play | pick | pause | ending | result | menu
  clock: 0,        // 연출용 시계
  keys: {},
  joy: { active: false, id: null, ox: 0, oy: 0, x: 0, y: 0 },
  chapter: 0,      // 타이틀에서 고른 챕터
};
